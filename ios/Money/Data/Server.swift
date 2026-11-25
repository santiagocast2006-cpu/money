import Foundation
import Supabase

/// The Money project on Supabase. The publishable key is meant to ship in apps: row-level security decides
/// what anyone can read (owner only, and only after the authenticator-app step).
enum Server {
    static let url = URL(string: "https://qdfrlegiwsjlixmtqhyr.supabase.co")!
    static let publishableKey = "sb_publishable_dGaMpHlN7qRd9tPLs5atCA_EszUO4Ci"
    static let client = SupabaseClient(supabaseURL: url, supabaseKey: publishableKey,
                                       options: .init(auth: .init(emitLocalSessionAsInitialSession: true)))
}

enum AuthStep: Equatable { case checking, signIn, code(factorId: String), enroll, ready }

enum Api {
    private static var auth: AuthClient { Server.client.auth }

    /// Where sign-in stands: no session, password done but code missing, or fully in (aal2).
    static func step() async -> AuthStep {
        guard (try? await auth.session) != nil else { return .signIn }
        do {
            let aal = try await auth.mfa.getAuthenticatorAssuranceLevel()
            if aal.currentLevel == "aal2" { return .ready }
            let f = try await auth.mfa.listFactors()
            if let v = f.totp.first(where: { $0.status == .verified }) { return .code(factorId: v.id) }
            return .enroll
        } catch { return .signIn }
    }

    static func signIn(email: String, password: String) async throws {
        _ = try await auth.signIn(email: email, password: password)
    }
    static func verify(factorId: String, code: String) async throws {
        _ = try await auth.mfa.challengeAndVerify(params: MFAChallengeAndVerifyParams(factorId: factorId, code: code))
    }
    static func signOut() async { try? await auth.signOut() }
    static var email: String? { auth.currentSession?.user.email }

    /// Reads a table in pages: the server returns at most 1000 rows per request.
    private static func all<T: Decodable>(_ table: String, order: [(String, Bool)], since: (String, String)? = nil) async throws -> [T] {
        var out: [T] = [], from = 0
        while true {
            var q: PostgrestFilterBuilder = Server.client.from(table).select()
            if let since { q = q.gte(since.0, value: since.1) }
            var t: PostgrestTransformBuilder = q
            for (col, asc) in order { t = t.order(col, ascending: asc) }
            let page: [T] = try await t.range(from: from, to: from + 999).execute().value
            out += page
            if page.count < 1000 { return out }
            from += 1000
        }
    }

    static func load() async throws -> Snapshot {
        let since = Day.ymd(Day.add(Day.today, -120))
        async let a: [Account] = all("accounts", order: [("sort", true), ("id", true)])
        async let t: [Txn] = all("transactions", order: [("date", false), ("id", false)], since: ("date", since))
        async let b: [Bill] = all("bills", order: [("id", true)])
        async let s: [Sync] = Server.client.from("syncs").select().order("at", ascending: false).limit(1).execute().value
        async let f: [Fund] = all("funds", order: [("id", true)])
        async let m: [FundMember] = all("fund_members", order: [("id", true)])
        async let e: [FundEntry] = all("fund_entries", order: [("on_date", false), ("id", false)])
        return try await Snapshot(accounts: a, transactions: t, bills: b, syncs: s, funds: f, members: m, entries: e)
    }

    static func addEntry(_ e: NewEntry) async throws {
        try await Server.client.from("fund_entries").insert(e).execute()
    }
    static func deleteEntry(_ id: Int) async throws {
        try await Server.client.from("fund_entries").delete().eq("id", value: id).execute()
    }
}
