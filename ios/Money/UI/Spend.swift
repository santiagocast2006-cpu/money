import SwiftUI

struct SpendView: View {
    @Environment(Store.self) private var store
    @AppStorage("side") private var side: Side = .personal
    var body: some View {
        NavigationStack {
            Loaded { b in SpendList(b: b, side: side) }
                .navigationTitle("Spending")
                .toolbar { SidePicker(side: $side) }
                .refreshable { await store.reload() }
        }
    }
}

enum Period: String, CaseIterable { case cycle, month, days30 }

/// One account's spending over a period. Moving money between your own accounts, or paying a card, isn't spending.
private struct Spend {
    let label: String, tx: [Txn], spent: Double, paidIn: Double, pending: Double, count: Int
    let cats: [(String, Double)], places: [(String, Double)]

    init(_ b: Book, _ a: Account, _ p: Period) {
        let from: Date
        switch p {
        case .cycle:
            let sd = Day.parse(a.statementDate ?? "")
            from = Day.add(sd, 1); label = "since the \(Fmt.short(sd)) statement"
        case .days30: from = Day.add(b.today, -29); label = "in the last 30 days"
        case .month: from = Day.firstOfMonth(b.today); label = "this month"
        }
        tx = b.transactions(a.id).filter { Day.parse($0.date) >= from }
        let counts: (Txn) -> Bool = { !["Own transfer", "Card payment"].contains($0.category ?? "") }
        let out = tx.filter { $0.amount > 0 && counts($0) }
        spent = out.reduce(0) { $0 + $1.amount }
        paidIn = -tx.filter { $0.amount < 0 && counts($0) }.reduce(0) { $0 + $1.amount }
        pending = out.filter(\.pending).reduce(0) { $0 + $1.amount }
        count = out.count
        func group(_ key: (Txn) -> String) -> [(String, Double)] {
            Dictionary(grouping: out, by: key).map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.1 > $1.1 }
        }
        cats = group { ($0.category ?? "").isEmpty ? "Other" : $0.category! }
        places = Array(group { t in
            let n = t.merchant
                .replacingOccurrences(of: #"\s+(\*|#)\S*.*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+\d{2}/\d{2}$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? "Other" : n
        }.prefix(10))
    }
}

private struct SpendList: View {
    let b: Book, side: Side
    @State private var acctId: String?
    @State private var period: Period = .cycle

    var body: some View {
        let withTx = b.accounts(side).filter { !b.transactions($0.id).isEmpty }
        if withTx.isEmpty {
            ContentUnavailableView("No \(side.rawValue) transactions yet", systemImage: "list.bullet",
                                   description: Text("They arrive with the morning sync."))
        } else {
            let a = withTx.first { $0.id == acctId } ?? withTx.first(where: \.isCard) ?? withTx[0]
            let p: Period = period == .cycle && a.statementDate == nil ? .month : period
            let s = Spend(b, a, p)
            List {
                Section {
                    Picker("Account", selection: Binding(get: { a.id }, set: { acctId = $0 })) {
                        ForEach(withTx) { Text($0.label).tag($0.id) }
                    }
                    Picker("Period", selection: Binding(get: { p }, set: { period = $0 })) {
                        if a.statementDate != nil { Text("This cycle").tag(Period.cycle) }
                        Text("This month").tag(Period.month)
                        Text("30 days").tag(Period.days30)
                    }.pickerStyle(.segmented)
                    Big(label: "Spent \(s.label)", value: Fmt.usd(s.spent),
                        sub: ["\(s.count) charges", s.pending > 0 ? "\(Fmt.usd(s.pending)) still pending" : nil,
                              s.paidIn > 0 ? "\(Fmt.usd(s.paidIn)) paid in" : nil].compactMap { $0 }.joined(separator: " · "))
                }
                Section("By category") { Bars(list: s.cats) }
                Section("Top places") { Bars(list: s.places) }
                Section {
                    ForEach(s.tx.prefix(100)) { TxRow(t: $0) }
                } header: { Text("Transactions") } footer: {
                    if s.tx.count > 100 { Text("Showing the latest 100 of \(s.tx.count).") }
                }
            }
        }
    }
}
