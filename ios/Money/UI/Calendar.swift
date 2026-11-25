import SwiftUI

struct CalendarView: View {
    @Environment(Store.self) private var store
    @AppStorage("side") private var side: Side = .personal
    var body: some View {
        NavigationStack {
            Loaded { b in CalendarList(b: b, side: side) }
                .navigationTitle("Calendar")
                .toolbar { SidePicker(side: $side) }
                .refreshable { await store.reload() }
        }
    }
}

private struct CalendarList: View {
    let b: Book, side: Side
    @State private var month = Day.firstOfMonth(Day.today)
    @State private var selected: String?
    @AppStorage("calSubs") private var subsOnly = true

    var body: some View {
        let first = month, last = Day.lastOfMonth(month)
        let items = b.calendar(first: first, last: last, side: side, subsOnly: subsOnly)
        let byDay = Dictionary(grouping: items) { Day.ymd($0.date) }
        let isNow = Day.firstOfMonth(b.today) == first
        let ahead = isNow || first > b.today
        let sel = selected.flatMap { $0.hasPrefix(String(Day.ymd(first).prefix(7))) ? $0 : nil }
        let days = sel.map { [$0] } ?? byDay.keys.sorted()

        List {
            Section {
                HStack {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").padding(8) }.accessibilityLabel("Previous month")
                    Spacer()
                    Text(Fmt.month(first)).font(.headline)
                    Spacer()
                    if !isNow { Button("Today") { month = Day.firstOfMonth(b.today); selected = nil }.font(.subheadline) }
                    Button { move(1) } label: { Image(systemName: "chevron.right").padding(8) }.accessibilityLabel("Next month")
                }
                .buttonStyle(.borderless)
                Picker("Show", selection: $subsOnly) {
                    Text("Subscriptions").tag(true)
                    Text("Everything").tag(false)
                }.pickerStyle(.segmented)
                MonthGrid(first: first, byDay: byDay, today: b.today, selected: $selected)
                Legend()
            }
            Section {
                LabeledContent("\(subsOnly ? "Subscriptions" : "Bills and subscriptions") this month", value: Fmt.usd(sum(items)))
                LabeledContent("Paid", value: Fmt.usd(sum(items.filter { $0.paid != nil })))
                if ahead { LabeledContent("Still to come", value: Fmt.usd(sum(items.filter { $0.status == .due }))) }
                else { LabeledContent("Was due, not seen", value: Fmt.usd(sum(items.filter { $0.status == .missed }))) }
                if subsOnly { LabeledContent("Subscriptions, average month", value: Fmt.usd(b.subsPerMonth(side: side))) }
            }
            if items.isEmpty {
                Section { Text("Nothing due this month.").foregroundStyle(.secondary) }
            } else if let sel, (byDay[sel] ?? []).isEmpty {
                Section(Fmt.day(Day.parse(sel))) {
                    Text("Nothing due this day.").foregroundStyle(.secondary)
                    Button("Show the whole month") { selected = nil }
                }
            } else {
                ForEach(days, id: \.self) { k in
                    Section {
                        ForEach(byDay[k] ?? []) { CalRow(i: $0) }
                        if sel != nil { Button("Show the whole month") { selected = nil } }
                    } header: { Text(Fmt.day(Day.parse(k))) } footer: {
                        if k == days.last && items.contains(where: { $0.status == .missed }) {
                            Text("\"Not seen\" means no charge with that name and a close amount turned up in the paying account within 5 days. It may have been charged under another name, on another card, or been cancelled.")
                        }
                    }
                }
            }
        }
    }

    private func sum(_ l: [Item]) -> Double { l.reduce(0) { $0 + ($1.amt ?? 0) } }
    private func move(_ n: Int) { month = Day.addMonths(month, n); selected = nil }
}

private struct MonthGrid: View {
    let first: Date, byDay: [String: [Item]], today: Date
    @Binding var selected: String?
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    var body: some View {
        let y = Day.year(first), m = Day.month(first), n = Day.daysInMonth(y, m), lead = Day.weekday(first)
        // One list with unique ids: separate ForEach blocks with overlapping ids (0-6, 1-30) collapse in a lazy grid.
        let heads = ["S", "M", "T", "W", "T", "F", "S"].enumerated().map { ("w\($0.offset)", $0.element) }
        LazyVGrid(columns: cols, spacing: 3) {
            ForEach(heads, id: \.0) { h in Text(h.1).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach((0..<lead).map { "b\($0)" }, id: \.self) { _ in Color.clear.frame(height: 50) }
            ForEach((1...n).map { Day.make(y, m, $0) }, id: \.self) { d in cell(d) }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ d: Date) -> some View {
        let k = Day.ymd(d), l = byDay[k] ?? [], isToday = d == today, isSel = selected == k
        let total = l.reduce(0) { $0 + ($1.amt ?? 0) }, anyUnknown = l.contains { $0.amt == nil }
        return Button { selected = isSel ? nil : k } label: {
            VStack(spacing: 3) {
                Text("\(Day.dayOfMonth(d))").font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                HStack(spacing: 2) {
                    ForEach(Array(l.prefix(4).enumerated()), id: \.offset) { _, i in Circle().fill(i.status.color).frame(width: 5, height: 5) }
                }.frame(height: 5)
                Text(l.isEmpty ? " " : total > 0 ? Fmt.k(total) + (anyUnknown ? "+" : "") : anyUnknown ? "?" : "$0")
                    .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isSel ? Color.accentColor.opacity(0.22) : isToday ? Color.accentColor.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(d < today && !isSel ? 0.65 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Fmt.day(d)): " + (l.isEmpty ? "nothing due" : "\(l.count) charge\(l.count > 1 ? "s" : ""), \(Fmt.usd(total))"))
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([(Status.due, "due"), (.paid, "paid"), (.missed, "not seen"), (.unknown, "before first sync")], id: \.1) { s, t in
                HStack(spacing: 4) { Circle().fill(s.color).frame(width: 7, height: 7); Text(t) }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

private struct CalRow: View {
    let i: Item
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.bill.name)
                Text([Fmt.day(i.date), whereFrom(i.from), why, i.bill.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            amount
        }
    }
    private var why: String? {
        switch i.status {
        case .unknown: return "before the first sync"
        case .missed: return "no matching charge on \(i.from?.name ?? "the account") within 5 days"
        default: return (i.paid?.parts ?? 1) > 1 ? "in \(i.paid!.parts) payments" : nil
        }
    }
    @ViewBuilder private var amount: some View {
        let money = i.amt.map { Fmt.usd($0) }
        switch i.status {
        case .paid: Pill("paid \(money ?? "")", .green)
        case .pending: Pill("pending \(money ?? "")", .teal)
        case .missed: VStack(alignment: .trailing, spacing: 2) { Pill("not seen", .orange); if let money { Text(money).font(.caption).foregroundStyle(.secondary) } }
        case .unknown: Text(money ?? "—").foregroundStyle(.secondary).monospacedDigit()
        case .due: if let money { Text(money).monospacedDigit() } else { Pill("amount?", .orange) }
        }
    }
}
