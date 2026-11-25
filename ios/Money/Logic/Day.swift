import Foundation

/// Calendar days at local midnight, and the "YYYY-MM-DD" strings the database uses.
enum Day {
    static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()
    static var today: Date { cal.startOfDay(for: Date()) }

    static func make(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d)) ?? today
    }
    static func parse(_ s: String) -> Date {
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? make(p[0], p[1], p[2]) : today
    }
    static func ymd(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
    static func addMonths(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .month, value: n, to: d) ?? d }
    /// b minus a, in whole days.
    static func diff(_ a: Date, _ b: Date) -> Int { cal.dateComponents([.day], from: a, to: b).day ?? 0 }
    static func year(_ d: Date) -> Int { cal.component(.year, from: d) }
    static func month(_ d: Date) -> Int { cal.component(.month, from: d) }
    static func dayOfMonth(_ d: Date) -> Int { cal.component(.day, from: d) }
    /// 0 = Sunday, like the database's `weekday` column.
    static func weekday(_ d: Date) -> Int { cal.component(.weekday, from: d) - 1 }
    static func daysInMonth(_ y: Int, _ m: Int) -> Int { cal.range(of: .day, in: .month, for: make(y, m, 1))?.count ?? 30 }
    static func firstOfMonth(_ d: Date) -> Date { make(year(d), month(d), 1) }
    static func lastOfMonth(_ d: Date) -> Date { make(year(d), month(d), daysInMonth(year(d), month(d))) }
}

enum Fmt {
    private static func number(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal
        f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
        return f
    }
    private static let n2 = number(2), n0 = number(0)
    private static func dates(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format; return f
    }
    private static let dDay = dates("EEE, MMM d"), dShort = dates("MMM d"), dMonth = dates("MMMM yyyy"),
                        dMonthName = dates("MMMM"), dMon = dates("MMM"), dMonYear = dates("MMM yyyy"), dStamp = dates("MMM d, h:mm a")

    static func usd(_ n: Double?, cents: Bool = true) -> String {
        guard let n, n.isFinite else { return "—" }
        let s = (cents ? n2 : n0).string(from: NSNumber(value: abs(n))) ?? "0"
        return (n < 0 ? "−" : "") + "$" + s
    }
    static func usd0(_ n: Double?) -> String { usd(n, cents: false) }
    /// $1.5k, $12k: short totals for calendar cells.
    static func k(_ n: Double) -> String {
        guard n >= 1000 else { return usd0(n) }
        var s = String(format: n >= 10000 ? "%.0f" : "%.1f", n / 1000)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return "$" + s + "k"
    }
    static func ord(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 { case 1: return "\(n)st"; case 2: return "\(n)nd"; case 3: return "\(n)rd"; default: return "\(n)th" }
    }
    static func day(_ d: Date) -> String { dDay.string(from: d) }
    static func short(_ d: Date) -> String { dShort.string(from: d) }
    static func month(_ d: Date) -> String { dMonth.string(from: d) }
    static func monthName(_ d: Date) -> String { dMonthName.string(from: d) }
    static func mon(_ d: Date) -> String { dMon.string(from: d) }
    static func monYear(_ d: Date) -> String { dMonYear.string(from: d) }
    /// "Nov 25, 9:02 AM" from a database timestamp.
    static func stamp(_ iso: String) -> String {
        let plain = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: plain) else { return iso }
        return dStamp.string(from: d)
    }
}
