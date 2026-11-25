import SwiftUI

struct MainTabs: View {
    @AppStorage("side") private var side: Side = .personal
    var body: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") { TodayView() }
            Tab("Accounts", systemImage: "creditcard") { AccountsView() }
            Tab("Spending", systemImage: "chart.bar") { SpendView() }
            Tab("Calendar", systemImage: "calendar") { CalendarView() }
            if side == .personal { Tab("Funds", systemImage: "person.3") { FundsView() } }
        }
    }
}

/// Shows the screen once data is loaded; a spinner or the error until then.
struct Loaded<Content: View>: View {
    @Environment(Store.self) private var store
    @ViewBuilder let content: (Book) -> Content
    var body: some View {
        if let b = store.book {
            content(b)
        } else if let e = store.error {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "wifi.exclamationmark")
            } description: { Text(e) } actions: {
                Button("Try again") { Task { await store.reload() } }
            }
        } else {
            ProgressView("Loading…")
        }
    }
}

/// Personal / Business, in the top-right of every tab.
struct SidePicker: ToolbarContent {
    @Binding var side: Side
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Side", selection: $side) { ForEach(Side.allCases) { Text($0.title).tag($0) } }
            } label: {
                Text(side.title).font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("Showing \(side.title). Switch side")
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, _ color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

extension Status {
    var color: Color {
        switch self {
        case .paid: .green
        case .pending: .teal
        case .due: .accentColor
        case .missed: .orange
        case .unknown: .gray
        }
    }
}

func whereFrom(_ a: Account?) -> String { a.map { ($0.isCard ? "on " : "from ") + $0.label } ?? "account not set" }

/// A bill on a day: name, when and from where, and its amount or what was found.
struct ItemRow: View {
    let item: Item
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.bill.name)
                Text([Fmt.day(item.date), whereFrom(item.from), item.bill.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            amount
        }
    }
    @ViewBuilder private var amount: some View {
        let b = item.bill
        if let p = item.paid { Pill("\(p.pending ? "pending" : "paid") \(Fmt.usd(p.amount))", .green) }
        else if b.amount == nil { Pill("amount?", .orange) }
        else if let mx = b.amountMax { Text("\(Fmt.usd0(b.amount))–\(Fmt.usd0(mx).dropFirst())").monospacedDigit() }
        else { Text(Fmt.usd(b.amount)).monospacedDigit() }
    }
}

struct TxRow: View {
    let t: Txn
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.merchant).lineLimit(2)
                Text([Fmt.short(Day.parse(t.date)), t.category, t.pending ? "pending" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(t.amount < 0 ? "+" + Fmt.usd(-t.amount) : Fmt.usd(t.amount))
                .monospacedDigit().foregroundStyle(t.amount < 0 ? Color.green : Color.primary)
        }
    }
}

/// Horizontal bars, largest first.
struct Bars: View {
    let list: [(String, Double)]
    var body: some View {
        if list.isEmpty {
            Text("No charges.").foregroundStyle(.secondary)
        } else {
            let top = max(list.first?.1 ?? 1, 0.01)
            ForEach(Array(list.enumerated()), id: \.offset) { _, kv in
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(kv.0).lineLimit(1); Spacer(); Text(Fmt.usd0(kv.1)).monospacedDigit() }
                    ProgressView(value: min(kv.1, top), total: top)
                }
            }
        }
    }
}

struct Big: View {
    let label: String, value: String
    var sub: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            if let sub { Text(sub).font(.footnote).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}

/// How full a card is: green, then orange past half, red past 90%.
struct Meter: View {
    let used: Double
    var body: some View {
        ProgressView(value: min(max(used, 0), 1))
            .tint(used > 0.9 ? .red : used > 0.5 ? .orange : .green)
    }
}
