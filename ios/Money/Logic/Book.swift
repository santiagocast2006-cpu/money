import Foundation

enum Side: String, CaseIterable, Identifiable {
    case personal, business
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A charge found in the paying account that settles a bill (several summed when it was split).
struct Paid: Hashable { let amount: Double; let pending: Bool; let parts: Int }

/// paid / pending: found in the paying account. due: still ahead. missed: date passed and nothing matched.
/// unknown: before the first transaction read from that account.
enum Status: String { case paid, pending, due, missed, unknown }

struct Item: Identifiable, Hashable {
    let date: Date, bill: Bill, from: Account?, paid: Paid?
    var status: Status = .due
    var amt: Double? = nil
    var id: String { "\(bill.id)-\(Day.ymd(date))" }
}

struct Need { let items: [Item]; let low: Double; let high: Double; let unknown: [Item] }

struct FundRow: Identifiable {
    let m: FundMember, per: Double, paid: Double, byMonth: [String: Double], owes: Double
    var id: Int { m.id }
}

struct FundState {
    let fund: Fund, members: [FundMember], rows: [FundRow], entries: [FundEntry]
    let months: Int, all: [Date], goal: Double?, expected: Double, actual: Double, out: Double, monthlyTotal: Double
}

/// The loaded data plus everything worked out from it. Same rules as the website (web/app.js).
struct Book {
    let s: Snapshot
    let today: Date
    private let byId: [String: Account]
    private let txBy: [String: [Txn]]
    private let firstTx: [String: String]

    init(_ s: Snapshot) {
        self.s = s
        today = Day.today
        byId = Dictionary(s.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        txBy = Dictionary(grouping: s.transactions, by: \.accountId)
        var first: [String: String] = [:]
        for t in s.transactions {
            let d = String(t.date.prefix(10))
            if let have = first[t.accountId], have <= d { continue }
            first[t.accountId] = d
        }
        firstTx = first
    }

    func acct(_ id: String?) -> Account? { id.flatMap { byId[$0] } }
    func accounts(_ side: Side) -> [Account] { s.accounts.filter { $0.scope == side.rawValue } }
    func transactions(_ accountId: String) -> [Txn] { txBy[accountId] ?? [] }
    /// The paying account decides the side; a bill with no account uses its own.
    func sideOf(_ b: Bill) -> String { acct(b.payFrom)?.scope ?? b.scope }

    func occurrences(_ b: Bill, _ from: Date, _ to: Date) -> [Date] {
        var out: [Date] = []
        guard b.active, from <= to else { return out }
        switch b.cadence {
        case "monthly":
            guard let day = b.day else { break }
            var m = Day.firstOfMonth(from)
            while m <= to {
                let y = Day.year(m), mo = Day.month(m)
                let d = Day.make(y, mo, min(day, Day.daysInMonth(y, mo)))
                if d >= from && d <= to { out.append(d) }
                m = Day.addMonths(m, 1)
            }
        case "yearly":
            guard let month = b.month, let day = b.day else { break }
            for y in Day.year(from)...Day.year(to) {
                let d = Day.make(y, month, min(day, Day.daysInMonth(y, month)))
                if d >= from && d <= to { out.append(d) }
            }
        case "weekly":
            guard let wd = b.weekday, (0...6).contains(wd) else { break }
            var d = from
            while Day.weekday(d) != wd { d = Day.add(d, 1) }
            while d <= to { out.append(d); d = Day.add(d, 7) }
        case "interval":
            guard let n = b.intervalDays, n > 0, let start = b.startDate else { break }
            var d = Day.parse(start)
            if d < from { d = Day.add(d, Int((Double(Day.diff(d, from)) / Double(n)).rounded(.up)) * n) }
            while d <= to { out.append(d); d = Day.add(d, n) }
        case "once":
            guard let start = b.startDate else { break }
            let d = Day.parse(start)
            if d >= from && d <= to { out.append(d) }
        default: break
        }
        return out
    }

    /// Paid when the paying account shows a charge near the date whose merchant has the bill's word
    /// (bill.match, else the first word of its name) and whose amount fits (80-120%; a card minimum has no top).
    func paidBy(_ b: Bill, _ d: Date) -> Paid? {
        guard let pf = b.payFrom, d <= Day.add(today, 3) else { return nil }
        let word: String = {
            if let m = b.match, !m.isEmpty { return m.lowercased() }
            return String(b.name.split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace || $0 == "(" }).first ?? "").lowercased()
        }()
        let (back, ahead) = b.kind == "card_minimum" ? (25, 3) : (5, 5)
        let near = transactions(pf).filter { t in
            guard t.amount > 0 else { return false }
            let gap = Day.diff(d, Day.parse(t.date))
            return gap >= -back && gap <= ahead && t.merchant.lowercased().contains(word)
        }
        guard !near.isEmpty else { return nil }
        let lo = b.amount.map { $0 * 0.8 } ?? 0
        let hi = (b.kind == "card_minimum" || b.amount == nil) ? Double.infinity : (b.amountMax ?? b.amount ?? 0) * 1.2
        if let one = near.first(where: { $0.amount >= lo && $0.amount <= hi }) {
            return Paid(amount: one.amount, pending: one.pending, parts: 1)
        }
        let total = near.reduce(0) { $0 + $1.amount }
        if near.count > 1 && total >= lo && total <= hi {
            return Paid(amount: total, pending: near.contains { $0.pending }, parts: near.count)
        }
        return nil
    }

    /// Every bill due from today to `days` ahead. `side` nil = both sides.
    func upcoming(days: Int, side: Side?) -> [Item] {
        let to = Day.add(today, days)
        var items: [Item] = []
        for b in s.bills {
            if let side, sideOf(b) != side.rawValue { continue }
            for d in occurrences(b, today, to) { items.append(Item(date: d, bill: b, from: acct(b.payFrom), paid: paidBy(b, d))) }
        }
        return items.sorted { $0.date != $1.date ? $0.date < $1.date : ($0.bill.amount ?? 0) > ($1.bill.amount ?? 0) }
    }

    /// What has to come out of checking/savings. A bill charged to a card adds to the card instead.
    func cashNeed(days: Int, side: Side?) -> Need {
        let items = upcoming(days: days, side: side).filter { !($0.from?.isCard ?? false) && $0.paid == nil }
        let known = items.filter { $0.bill.amount != nil }
        return Need(items: items,
                    low: known.reduce(0) { $0 + ($1.bill.amount ?? 0) },
                    high: known.reduce(0) { $0 + ($1.bill.amountMax ?? $1.bill.amount ?? 0) },
                    unknown: items.filter { $0.bill.amount == nil })
    }

    /// One month of charges with a status each, for the calendar.
    func calendar(first: Date, last: Date, side: Side, subsOnly: Bool) -> [Item] {
        var items: [Item] = []
        for b in s.bills {
            if subsOnly && b.kind != "subscription" { continue }
            let from = acct(b.payFrom)
            if (from?.scope ?? b.scope) != side.rawValue { continue }
            for d in occurrences(b, first, last) {
                let paid = paidBy(b, d)
                let read = from.flatMap { firstTx[$0.id] }.map { $0 <= Day.ymd(d) } ?? false
                var i = Item(date: d, bill: b, from: from, paid: paid)
                i.status = paid.map { $0.pending ? .pending : .paid } ?? (d >= today ? .due : read ? .missed : .unknown)
                i.amt = paid?.amount ?? b.amount
                items.append(i)
            }
        }
        return items.sorted { $0.date != $1.date ? $0.date < $1.date : ($0.amt ?? 0) > ($1.amt ?? 0) }
    }

    func perMonth(_ b: Bill) -> Double {
        let a = b.amountMax ?? b.amount ?? 0
        switch b.cadence {
        case "monthly": return a
        case "yearly": return a / 12
        case "weekly": return a * 52 / 12
        case "interval": return b.intervalDays.map { a * 365 / 12 / Double($0) } ?? 0
        default: return 0
        }
    }
    func subsPerMonth(side: Side) -> Double {
        s.bills.filter { $0.active && $0.kind == "subscription" && sideOf($0) == side.rawValue }.reduce(0) { $0 + perMonth($1) }
    }

    // MARK: Funds: each member puts in a set amount every month.

    private func monthsBetween(_ a: Date, _ b: Date) -> Int { (Day.year(b) - Day.year(a)) * 12 + (Day.month(b) - Day.month(a)) + 1 }
    /// Months that should be paid by the end of this month (capped at the fund's last month).
    private func monthsIn(_ f: Fund) -> Int {
        let start = Day.parse(f.startMonth)
        let end = f.endMonth.map(Day.parse).flatMap { $0 < today ? $0 : nil } ?? today
        return max(0, monthsBetween(start, end))
    }
    private func fundMonths(_ f: Fund) -> [Date] {
        let start = Day.firstOfMonth(Day.parse(f.startMonth))
        let n = monthsBetween(start, f.endMonth.map(Day.parse) ?? today)
        return n > 0 ? (0..<n).map { Day.addMonths(start, $0) } : []
    }

    func fundState(_ f: Fund) -> FundState {
        let members = s.members.filter { $0.fundId == f.id }.sorted { $0.sort != $1.sort ? $0.sort < $1.sort : $0.name < $1.name }
        let entries = s.entries.filter { $0.fundId == f.id }
        let deposits = entries.filter { $0.kind == "deposit" }
        let out = entries.filter { $0.kind == "withdrawal" }.reduce(0) { $0 + $1.amount }
        let months = monthsIn(f)
        let rows = members.map { m -> FundRow in
            let per = m.monthly ?? f.monthlyPerPerson
            let mine = deposits.filter { $0.memberId == m.id }
            let paid = mine.reduce(0) { $0 + $1.amount }
            var by: [String: Double] = [:]
            for e in mine { by[String((e.month ?? e.onDate).prefix(7)), default: 0] += e.amount }
            return FundRow(m: m, per: per, paid: paid, byMonth: by, owes: max(0, per * Double(months) - paid))
        }
        let put = deposits.reduce(0) { $0 + $1.amount }
        let monthly = rows.reduce(0) { $0 + $1.per }
        let all = fundMonths(f)
        let goal = f.goal ?? (f.endMonth != nil ? monthly * Double(all.count) : nil)
        return FundState(fund: f, members: members, rows: rows, entries: entries, months: months, all: all, goal: goal,
                         expected: monthly * Double(months) - out, actual: put - out, out: out, monthlyTotal: monthly)
    }
}
