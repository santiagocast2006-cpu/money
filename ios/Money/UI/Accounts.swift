import SwiftUI

struct AccountsView: View {
    @Environment(Store.self) private var store
    @AppStorage("side") private var side: Side = .personal
    var body: some View {
        NavigationStack {
            Loaded { b in
                List {
                    ForEach([("Cards", b.accounts(side).filter(\.isCard)), ("Cash", b.accounts(side).filter(\.isCash))], id: \.0) { title, list in
                        if !list.isEmpty {
                            Section(title) {
                                ForEach(list) { a in NavigationLink { AccountDetail(id: a.id) } label: { AccountRow(a: a, b: b) } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .toolbar { SidePicker(side: $side) }
            .refreshable { await store.reload() }
        }
    }
}

private func used(_ a: Account) -> Double? {
    guard let l = a.creditLimit, l > 0, let o = a.owed else { return nil }
    return o / l
}

private struct AccountRow: View {
    let a: Account, b: Book
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.label)
                    Text(a.institution).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(a.isCard ? Fmt.usd(a.owed) : Fmt.usd(a.balance == nil && a.available == nil ? nil : a.cash)).monospacedDigit()
            }
            let warns = warnings
            if !warns.isEmpty { HStack { ForEach(warns, id: \.0) { Pill($0.0, $0.1) } } }
            if let u = used(a) { Meter(used: u) }
        }.padding(.vertical, 2)
    }
    private var warnings: [(String, Color)] {
        var w: [(String, Color)] = []
        if let u = used(a), u >= 0.9 { w.append(("\(Int((u * 100).rounded()))% of limit", .red)) }
        if let auto = a.autopay, a.isCard,
           let from = b.s.accounts.first(where: { $0.isCash && $0.mask.map { auto.contains($0) } == true }), from.cash < 50 {
            w.append(("AutoPay account has \(Fmt.usd(from.cash))", .orange))
        }
        if a.balance == nil && (a.isCard || a.available == nil) { w.append(("not read yet", .gray)) }
        return w
    }
}

struct AccountDetail: View {
    @Environment(Store.self) private var store
    let id: String
    var body: some View {
        Loaded { b in
            if let a = b.acct(id) {
                let tx = b.transactions(a.id)
                List {
                    Section {
                        if a.isCard {
                            Big(label: "Owed", value: Fmt.usd(a.owed),
                                sub: a.pending != 0 ? "\(Fmt.usd(a.balance)) posted + \(Fmt.usd(a.pending)) pending" : nil)
                            if let u = used(a) { Meter(used: u) }
                        } else {
                            Big(label: "Available", value: Fmt.usd(a.balance == nil && a.available == nil ? nil : a.cash),
                                sub: a.available != nil && a.balance != nil && a.available != a.balance ? "\(Fmt.usd(a.balance)) balance" : nil)
                        }
                    }
                    Section {
                        if let l = a.creditLimit { LabeledContent("Limit", value: Fmt.usd0(l)) }
                        if a.isCard, let l = a.creditLimit, let o = a.owed { LabeledContent("Available", value: Fmt.usd(l - o)) }
                        if let s = a.statementBalance {
                            LabeledContent("Last statement", value: Fmt.usd(s) + (a.statementDate.map { " · " + Fmt.short(Day.parse($0)) } ?? ""))
                        }
                        if let d = a.closeDay { LabeledContent("Statement closes", value: "the \(Fmt.ord(d))") }
                        if let d = a.dueDay { LabeledContent("Payment due", value: "the \(Fmt.ord(d))") }
                        if let s = a.autopay { LabeledContent("AutoPay", value: s) }
                        if let s = a.rewards { LabeledContent("Rewards", value: s) }
                        if let s = a.note { Text(s).font(.footnote).foregroundStyle(.secondary) }
                    } footer: { if let s = a.asOf { Text("As of \(Fmt.stamp(s))") } }
                    Section("Latest") {
                        if tx.isEmpty { Text("No transactions read yet.").foregroundStyle(.secondary) }
                        ForEach(tx.prefix(60)) { TxRow(t: $0) }
                    }
                }
                .navigationTitle(a.label)
            } else {
                ContentUnavailableView("Account not found", systemImage: "questionmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
    }
}
