import SwiftUI

struct FundsView: View {
    @Environment(Store.self) private var store
    var body: some View {
        NavigationStack {
            Loaded { b in FundsList(b: b) }
                .navigationTitle("Funds")
                .refreshable { await store.reload() }
        }
    }
}

private struct PayAsk: Identifiable {
    let fund: Fund, member: FundMember, amount: Double, month: Date
    var id: String { "\(fund.id)-\(member.id)-\(Day.ymd(month))" }
}

private struct FundsList: View {
    let b: Book
    @Environment(Store.self) private var store
    @State private var ask: PayAsk?
    @State private var withdraw: Fund?
    @State private var err: String?

    var body: some View {
        if b.s.funds.isEmpty {
            ContentUnavailableView("No funds yet", systemImage: "person.3")
        } else {
            List {
                ForEach(b.s.funds) { f in FundSection(st: b.fundState(f), today: b.today, ask: $ask, withdraw: $withdraw) }
            }
            .confirmationDialog(ask.map { "Mark \($0.member.name) paid for \(Fmt.monthName($0.month))?" } ?? "",
                                isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
                                titleVisibility: .visible, presenting: ask) { a in
                Button("Mark paid \(Fmt.usd0(a.amount))") {
                    Task {
                        do {
                            try await store.addEntry(NewEntry(fund_id: a.fund.id, member_id: a.member.id, kind: "deposit",
                                                              month: Day.ymd(a.month), amount: a.amount, on_date: Day.ymd(Day.today), note: nil))
                        } catch { err = Store.say(error) }
                    }
                }
            }
            .sheet(item: $withdraw) { f in WithdrawSheet(fund: f) { msg in err = msg } }
            .alert("Didn't save", isPresented: Binding(get: { err != nil }, set: { if !$0 { err = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(err ?? "") }
        }
    }
}

private struct FundSection: View {
    let st: FundState, today: Date
    @Binding var ask: PayAsk?
    @Binding var withdraw: Fund?

    var body: some View {
        let f = st.fund
        let behind = st.expected - st.actual
        let started = st.months > 0
        let last = st.all.last
        let over = f.endMonth.map { Day.parse($0) < Day.firstOfMonth(today) } ?? false
        let owers = st.rows.filter { $0.owes > 0 }
        Section {
            LabeledContent("Has") { Text(Fmt.usd0(st.actual)).font(.title3.weight(.semibold)).monospacedDigit() }
            if started {
                LabeledContent(over ? "Should have" : "Should have by \(Fmt.short(Day.lastOfMonth(today)))", value: Fmt.usd0(st.expected))
            } else {
                LabeledContent("Starts", value: Fmt.short(Day.parse(f.startMonth)))
            }
            if let g = st.goal {
                LabeledContent(f.endMonth != nil ? "At the end (\(last.map(Fmt.mon) ?? ""))" : "Goal", value: Fmt.usd0(g))
                ProgressView(value: min(max(st.actual, 0), g), total: max(g, 1))
            }
            if started {
                if behind > 0 {
                    Label("\(Fmt.usd0(behind)) behind: " + owers.map { "\($0.m.name) \(Fmt.usd0($0.owes))" }.joined(separator: ", ") + ".",
                          systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else {
                    Label("Everyone is up to date.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            grid
            Button { withdraw = f } label: { Label("Take money out", systemImage: "arrow.up.right.circle") }
            NavigationLink { FundHistory(fundId: f.id) } label: { Text("History (\(st.entries.count))") }
        } header: {
            Text(f.name)
        } footer: {
            Text("Tap a month to mark it paid. \(Fmt.usd0(f.monthlyPerPerson)) each a month" +
                 (last.map { ", \(Fmt.mon(Day.parse(f.startMonth)))–\(Fmt.monYear($0))." } ?? ".") +
                 (f.heldIn.map { " Money sits in: \($0)." } ?? ""))
        }
    }

    private var grid: some View {
        let nowKey = String(Day.ymd(today).prefix(7))
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 5, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(st.all, id: \.self) { d in
                        Text(Fmt.mon(d)).font(.caption2.weight(.semibold))
                            .foregroundStyle(String(Day.ymd(d).prefix(7)) == nowKey ? Color.accentColor : Color.secondary)
                    }
                }
                ForEach(st.rows) { r in
                    GridRow {
                        Text(r.m.name).font(.subheadline).lineLimit(1).gridColumnAlignment(.leading)
                        ForEach(st.all, id: \.self) { d in monthCell(r, d) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func monthCell(_ r: FundRow, _ d: Date) -> some View {
        let got = r.byMonth[String(Day.ymd(d).prefix(7))] ?? 0
        let due = d <= today
        if got >= r.per {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(minWidth: 38, minHeight: 30)
                .accessibilityLabel("\(r.m.name) paid for \(Fmt.monthName(d))")
        } else {
            Button { ask = PayAsk(fund: st.fund, member: r.m, amount: r.per - got, month: d) } label: {
                Text(got > 0 ? Fmt.usd0(got) : due ? "owes" : "·")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 38, minHeight: 30)
                    .background(due ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(due ? Color.orange : Color.secondary)
            }
            .accessibilityLabel("Mark \(r.m.name) paid for \(Fmt.monthName(d))")
        }
    }
}

private struct WithdrawSheet: View {
    let fund: Fund
    let failed: (String) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Double?
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", value: $amount, format: .number).keyboardType(.decimalPad)
                    TextField("What for", text: $note)
                } footer: { Text("This records money taken out of \(fund.name). It doesn't move any money.") }
            }
            .navigationTitle("Take money out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") {
                        guard let amount, amount > 0 else { return }
                        busy = true
                        Task {
                            do {
                                try await store.addEntry(NewEntry(fund_id: fund.id, member_id: nil, kind: "withdrawal", month: nil,
                                                                  amount: amount, on_date: Day.ymd(Day.today), note: note.isEmpty ? nil : note))
                                dismiss()
                            } catch { failed(Store.say(error)); dismiss() }
                        }
                    }.disabled((amount ?? 0) <= 0 || busy)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct FundHistory: View {
    let fundId: Int
    @Environment(Store.self) private var store
    @State private var err: String?

    var body: some View {
        Loaded { b in
            let st = b.s.funds.first { $0.id == fundId }.map { b.fundState($0) }
            let entries = (st?.entries ?? []).sorted { $0.onDate != $1.onDate ? $0.onDate > $1.onDate : $0.id > $1.id }
            List {
                if entries.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    let who = st?.members.first { $0.id == e.memberId }?.name ?? ""
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.kind == "deposit" ? who + (e.month.map { " · " + Fmt.monYear(Day.parse($0)) } ?? "")
                                 : "Taken out" + (e.note.map { ": " + $0 } ?? ""))
                            Text([Fmt.short(Day.parse(e.onDate)), e.kind == "deposit" ? e.note : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((e.kind == "deposit" ? "+" : "−") + Fmt.usd0(e.amount)).monospacedDigit()
                            .foregroundStyle(e.kind == "deposit" ? Color.green : Color.primary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            Task { do { try await store.deleteEntry(e.id) } catch { err = Store.say(error) } }
                        }
                    }
                }
            }
            .navigationTitle(st?.fund.name ?? "History")
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("Didn't remove", isPresented: Binding(get: { err != nil }, set: { if !$0 { err = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(err ?? "") }
    }
}
