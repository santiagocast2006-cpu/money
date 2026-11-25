import Foundation

/// Reads a row by column name. Lenient about numbers: Postgres `numeric` can arrive as a JSON number or a string.
struct Col: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct Row {
    let c: KeyedDecodingContainer<Col>
    init(_ decoder: Decoder) throws { c = try decoder.container(keyedBy: Col.self) }
    func str(_ k: String) -> String? { try? c.decodeIfPresent(String.self, forKey: Col(k)) }
    func num(_ k: String) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: Col(k)) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: Col(k)) { return Double(s) }
        return nil
    }
    func int(_ k: String) -> Int? { num(k).map { Int($0) } }
    func bool(_ k: String) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: Col(k)) { return b }
        return num(k).map { $0 != 0 }
    }
    func strs(_ k: String) -> [String] { (try? c.decodeIfPresent([String].self, forKey: Col(k))) ?? [] }
}

struct Account: Decodable, Identifiable, Hashable {
    let id: String, institution: String, name: String, mask: String?, kind: String, scope: String
    let balance: Double?, available: Double?, creditLimit: Double?, pending: Double, statementBalance: Double?
    let statementDate: String?, closeDay: Int?, dueDay: Int?, autopay: String?, rewards: String?, asOf: String?, note: String?
    let sort: Int

    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.str("id") ?? ""; institution = r.str("institution") ?? ""; name = r.str("name") ?? ""
        mask = r.str("mask"); kind = r.str("kind") ?? ""; scope = r.str("scope") ?? "personal"
        balance = r.num("balance"); available = r.num("available"); creditLimit = r.num("credit_limit")
        pending = r.num("pending") ?? 0; statementBalance = r.num("statement_balance")
        statementDate = r.str("statement_date"); closeDay = r.int("close_day"); dueDay = r.int("due_day")
        autopay = r.str("autopay"); rewards = r.str("rewards"); asOf = r.str("as_of"); note = r.str("note")
        sort = r.int("sort") ?? 100
    }

    var isCash: Bool { kind == "checking" || kind == "savings" }
    var isCard: Bool { kind == "credit" }
    var label: String { mask.map { "\(name) ··\($0)" } ?? name }
    /// What can be spent from a cash account.
    var cash: Double { available ?? balance ?? 0 }
    /// What a card owes, pending charges included.
    var owed: Double? { balance.map { $0 + pending } }
}

struct Txn: Decodable, Identifiable, Hashable {
    let id: Int, accountId: String, date: String, merchant: String, category: String?, amount: Double, pending: Bool
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; accountId = r.str("account_id") ?? ""; date = r.str("date") ?? ""
        merchant = r.str("merchant") ?? ""; category = r.str("category"); amount = r.num("amount") ?? 0
        pending = r.bool("pending") ?? false
    }
}

struct Bill: Decodable, Identifiable, Hashable {
    let id: Int, name: String, amount: Double?, amountMax: Double?, cadence: String
    let day: Int?, month: Int?, weekday: Int?, intervalDays: Int?, startDate: String?
    let payFrom: String?, scope: String, kind: String, active: Bool, match: String?, note: String?
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; name = r.str("name") ?? ""; amount = r.num("amount"); amountMax = r.num("amount_max")
        cadence = r.str("cadence") ?? ""; day = r.int("day"); month = r.int("month"); weekday = r.int("weekday")
        intervalDays = r.int("interval_days"); startDate = r.str("start_date"); payFrom = r.str("pay_from")
        scope = r.str("scope") ?? "personal"; kind = r.str("kind") ?? "subscription"; active = r.bool("active") ?? true
        match = r.str("match"); note = r.str("note")
    }
}

struct Sync: Decodable, Hashable {
    let id: Int, at: String, sources: [String], missing: [String], note: String?
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; at = r.str("at") ?? ""; sources = r.strs("sources"); missing = r.strs("missing"); note = r.str("note")
    }
}

struct Fund: Decodable, Identifiable, Hashable {
    let id: Int, name: String, monthlyPerPerson: Double, startMonth: String, endMonth: String?, goal: Double?, heldIn: String?, note: String?
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; name = r.str("name") ?? ""; monthlyPerPerson = r.num("monthly_per_person") ?? 0
        startMonth = r.str("start_month") ?? ""; endMonth = r.str("end_month"); goal = r.num("goal")
        heldIn = r.str("held_in"); note = r.str("note")
    }
}

struct FundMember: Decodable, Identifiable, Hashable {
    let id: Int, fundId: Int, name: String, monthly: Double?, sort: Int
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; fundId = r.int("fund_id") ?? 0; name = r.str("name") ?? ""; monthly = r.num("monthly"); sort = r.int("sort") ?? 100
    }
}

struct FundEntry: Decodable, Identifiable, Hashable {
    let id: Int, fundId: Int, memberId: Int?, kind: String, month: String?, amount: Double, onDate: String, note: String?
    init(from decoder: Decoder) throws {
        let r = try Row(decoder)
        id = r.int("id") ?? 0; fundId = r.int("fund_id") ?? 0; memberId = r.int("member_id"); kind = r.str("kind") ?? "deposit"
        month = r.str("month"); amount = r.num("amount") ?? 0; onDate = r.str("on_date") ?? ""; note = r.str("note")
    }
}

/// A new fund deposit or withdrawal. The owner column fills itself in on the server.
struct NewEntry: Encodable {
    let fund_id: Int, member_id: Int?, kind: String, month: String?, amount: Double, on_date: String, note: String?
}

struct Snapshot {
    var accounts: [Account] = [], transactions: [Txn] = [], bills: [Bill] = [], syncs: [Sync] = []
    var funds: [Fund] = [], members: [FundMember] = [], entries: [FundEntry] = []
}
