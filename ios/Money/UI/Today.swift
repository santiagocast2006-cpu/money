import SwiftUI

struct TodayView: View {
    @Environment(Store.self) private var store
    @AppStorage("side") private var side: Side = .personal
    var body: some View {
        NavigationStack {
            Loaded { b in TodayList(b: b, side: side) }
                .navigationTitle("Today")
                .toolbar { SidePicker(side: $side) }
                .refreshable { await store.reload() }
        }
    }
}

private struct TodayList: View {
    let b: Book, side: Side
    @Environment(Store.self) private var store
    @State private var askSignOut = false

    var body: some View {
        let cash = b.accounts(side).filter(\.isCash)
        let total = cash.reduce(0) { $0 + $1.cash }
        let need = b.cashNeed(days: 14, side: side)
        let cards = b.accounts(side).filter(\.isCard)
        let next = Array(b.upcoming(days: 10, side: side).prefix(8))

        List {
            Section {
                Big(label: "\(side.title) cash", value: Fmt.usd(total), sub: "\(cash.count) account\(cash.count == 1 ? "" : "s")")
                LabeledContent("Due from it in 14 days",
                               value: need.low == need.high ? Fmt.usd(need.low) : Fmt.usd(need.low) + "–" + Fmt.usd(need.high).dropFirst())
                status(total: total, need: need)
                if !need.unknown.isEmpty {
                    Text("Not read yet: " + need.unknown.map { "\($0.bill.name) (\(Fmt.short($0.date)))" }.joined(separator: ", ") + ".")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(syncLine)
                    if let e = store.error { Text("Couldn't refresh: \(e)").foregroundStyle(.red) }
                }
            }

            Section("Next 10 days") {
                if next.isEmpty { Text("Nothing due.").foregroundStyle(.secondary) }
                ForEach(next) { ItemRow(item: $0) }
                NavigationLink("All upcoming") { UpcomingView() }
            }

            Section("Cards") {
                if cards.isEmpty { Text("No cards on this side.").foregroundStyle(.secondary) }
                else { cardsSummary(cards) }
                ForEach(cards) { a in
                    NavigationLink { AccountDetail(id: a.id) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label)
                                Text([a.dueDay.map { "due the \(Fmt.ord($0))" }, a.autopay].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let o = a.owed { Text(Fmt.usd(o)).monospacedDigit() } else { Pill("not read") }
                        }
                    }
                }
            }

            if side == .personal && !b.s.funds.isEmpty {
                Section("Funds") {
                    ForEach(b.s.funds) { f in
                        let st = b.fundState(f)
                        let behind = st.expected - st.actual
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                Text("\(st.members.count) people · \(Fmt.usd0(st.monthlyTotal)) a month").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Fmt.usd0(st.actual)).monospacedDigit()
                                Text(behind > 0 ? "\(Fmt.usd0(behind)) behind" : st.months > 0 ? "on track" : "starts \(Fmt.short(Day.parse(f.startMonth)))")
                                    .font(.caption).foregroundStyle(behind > 0 ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("Signed in as", value: Api.email ?? "")
                Button("Sign out", role: .destructive) { askSignOut = true }
            }
        }
        .confirmationDialog("Sign out of Money?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
        } message: { Text("You'll need your password and an authenticator code to get back in.") }
    }

    private var syncLine: String {
        guard let s = b.s.syncs.first else { return "Not synced yet." }
        return "Updated \(Fmt.stamp(s.at))" + (s.missing.isEmpty ? "" : " · not read: " + s.missing.joined(separator: ", "))
    }

    @ViewBuilder private func status(total: Double, need: Need) -> some View {
        let gap = total - need.high
        let n = need.unknown.count
        let unk = n == 0 ? "" : " plus \(n) amount\(n > 1 ? "s" : "") not read yet"
        if gap < 0 {
            Label("Short by \(Fmt.usd(-gap)) for the next 14 days\(unk).", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else if n > 0 {
            Label("Covered for now, with \(Fmt.usd(gap)) left\(unk).", systemImage: "questionmark.circle.fill").foregroundStyle(.orange)
        } else {
            Label("Covered, with \(Fmt.usd(gap)) left after the next 14 days.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private func cardsSummary(_ cards: [Account]) -> some View {
        let known = cards.filter { $0.balance != nil }
        let owed = known.reduce(0) { $0 + ($1.owed ?? 0) }
        let limited = cards.filter { ($0.creditLimit ?? 0) > 0 && $0.balance != nil }
        let limit = limited.reduce(0) { $0 + ($1.creditLimit ?? 0) }
        let used = limited.reduce(0) { $0 + ($1.owed ?? 0) }
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Owed on \(known.count) of \(cards.count) cards", value: Fmt.usd0(owed))
            if limit > 0 {
                Meter(used: used / limit)
                Text("\(Int((used / limit * 100).rounded()))% used on the \(limited.count) card\(limited.count > 1 ? "s" : "") with a known limit (\(Fmt.usd0(limit)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Cash each account needs for the bills still unpaid in the window, biggest first.
private struct AcctNeed { let key: String; let a: Account?; let sum: Double; let unk: Int }
private func cashByAccount(_ items: [Item]) -> [AcctNeed] {
    var out: [AcctNeed] = []
    for (key, list) in Dictionary(grouping: items, by: { $0.from?.id ?? "" }) {
        let sum = list.reduce(0.0) { $0 + ($1.bill.amountMax ?? $1.bill.amount ?? 0) }
        let unk = list.filter { $0.bill.amount == nil }.count
        if sum > 0 || unk > 0 { out.append(AcctNeed(key: key, a: list.first?.from, sum: sum, unk: unk)) }
    }
    return out.sorted { $0.sum > $1.sum }
}

struct UpcomingView: View {
    @Environment(Store.self) private var store
    @AppStorage("side") private var side: Side = .personal
    @State private var days = 45

    var body: some View {
        Loaded { b in
            let items = b.upcoming(days: days, side: side)
            let byDay = Dictionary(grouping: items) { Day.ymd($0.date) }
            let fromCash = items.filter { !($0.from?.isCard ?? false) && $0.paid == nil }
            let perAcct = cashByAccount(fromCash)
            List {
                Section {
                    Picker("How far", selection: $days) { ForEach([14, 45, 90], id: \.self) { Text("\($0) days").tag($0) } }
                        .pickerStyle(.segmented)
                }
                Section {
                    if perAcct.isEmpty { Text("Nothing due.").foregroundStyle(.secondary) }
                    ForEach(perAcct, id: \.key) { v in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.a?.label ?? "Account not set")
                                Text(needLine(v)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.usd(v.sum)).monospacedDigit().foregroundStyle(short(v) ? Color.red : Color.primary)
                        }
                    }
                } header: { Text("Cash needed by account") } footer: {
                    Text("Charges that go on a card are listed below but add to that card's balance, not to cash needed.")
                }
                ForEach(byDay.keys.sorted(), id: \.self) { k in
                    Section(Fmt.day(Day.parse(k))) { ForEach(byDay[k] ?? []) { ItemRow(item: $0) } }
                }
            }
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
    }

    private func needLine(_ v: AcctNeed) -> String {
        var parts: [String] = []
        if let a = v.a, a.isCash { parts.append("has " + Fmt.usd(a.cash)) }
        if v.unk > 0 { parts.append("\(v.unk) amount" + (v.unk > 1 ? "s" : "") + " not read") }
        return parts.joined(separator: " · ")
    }
    private func short(_ v: AcctNeed) -> Bool { (v.a?.isCash ?? false) && (v.a?.cash ?? 0) < v.sum }
}
