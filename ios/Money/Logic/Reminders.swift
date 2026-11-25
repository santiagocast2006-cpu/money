import Foundation
import UserNotifications

/// The evening before money leaves a checking or savings account: one reminder per day and account.
/// Card charges are left out (they only add to the card). Rebuilt on every load.
enum Reminders {
    private static let prefix = "money.due."

    static func schedule(_ b: Book) {
        Task {
            let c = UNUserNotificationCenter.current()
            guard (try? await c.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let old = await c.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            c.removePendingNotificationRequests(withIdentifiers: old)

            let items = b.upcoming(days: 30, side: nil).filter { $0.from?.isCash == true && $0.paid == nil && $0.date > b.today }
            let groups = Dictionary(grouping: items) { "\(Day.ymd($0.date))|\($0.from?.id ?? "")" }
            for (key, list) in groups.sorted(by: { $0.key < $1.key }).prefix(60) {
                guard let a = list.first?.from, let d = list.first?.date else { continue }
                let known = list.compactMap { $0.bill.amountMax ?? $0.bill.amount }
                let total = known.reduce(0, +)
                let content = UNMutableNotificationContent()
                content.title = "Due tomorrow from \(a.label)"
                content.body = list.map(\.bill.name).joined(separator: ", ") + ": " + Fmt.usd(total)
                    + (known.count < list.count ? " plus an amount not read yet" : "")
                    + (a.cash < total ? ". The last sync showed less than that in the account." : ".")
                content.sound = .default
                var when = Day.cal.dateComponents([.year, .month, .day], from: Day.add(d, -1))
                when.hour = 18; when.minute = 0
                guard let fire = Day.cal.date(from: when), fire > Date() else { continue }
                let req = UNNotificationRequest(identifier: prefix + key, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
                try? await c.add(req)
            }
        }
    }

    static func clear() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
}
