import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class Store {
    var step: AuthStep = .checking
    var book: Book?
    var error: String?
    var loading = false
    /// Debug builds only: showing Documents/fixture.json instead of the server (simulator checks).
    var usingFixture = false
    private var loadedAt: Date?

    func start() async {
        #if DEBUG
        if let snap = Self.fixture() { usingFixture = true; book = Book(snap); step = .ready; return }
        #endif
        step = await Api.step()
        if step == .ready { await reload() }
    }

    func reload() async {
        loading = true
        defer { loading = false }
        do {
            let b = Book(try await Api.load())
            book = b; loadedAt = Date(); error = nil
            Reminders.schedule(b)
        } catch {
            self.error = Self.say(error)
            let s = await Api.step()
            if s != .ready { step = s }
        }
    }

    func refreshIfStale() async {
        guard step == .ready else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        await reload()
    }

    func signIn(_ email: String, _ password: String) async throws {
        try await Api.signIn(email: email, password: password)
        step = await Api.step()
        if step == .ready { await reload() }
    }

    func verify(_ factorId: String, _ code: String) async throws {
        try await Api.verify(factorId: factorId, code: code)
        step = .ready
        await reload()
    }

    func signOut() async {
        await Api.signOut()
        book = nil; loadedAt = nil; step = .signIn
        Reminders.clear()
    }

    func addEntry(_ e: NewEntry) async throws { try await Api.addEntry(e); await reload() }
    func deleteEntry(_ id: Int) async throws { try await Api.deleteEntry(id); await reload() }

    #if DEBUG
    /// Simulator checks without signing in: Documents/fixture.json in the web's seed format. Debug builds only.
    private struct Fixture: Decodable {
        var accounts: [Account]?, transactions: [Txn]?, bills: [Bill]?, syncs: [Sync]?
        var funds: [Fund]?, members: [FundMember]?, entries: [FundEntry]?
    }
    static func fixture() -> Snapshot? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: dir.appendingPathComponent("fixture.json")),
              let f = try? JSONDecoder().decode(Fixture.self, from: data) else { return nil }
        return Snapshot(accounts: f.accounts ?? [], transactions: f.transactions ?? [], bills: f.bills ?? [], syncs: f.syncs ?? [],
                        funds: f.funds ?? [], members: f.members ?? [], entries: f.entries ?? [])
    }
    #endif

    static func say(_ e: Error) -> String {
        if let u = e as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(u.code) {
            return "No connection. Pull down to try again."
        }
        return e.localizedDescription
    }
}

/// Face ID (or the phone's passcode) before anything shows.
@MainActor @Observable
final class Lock {
    var locked = true
    var busy = false

    func unlock() async {
        guard locked, !busy else { return }
        let ctx = LAContext()
        var err: NSError?
        // No passcode on the phone: nothing to check against.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        busy = true
        defer { busy = false }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Money")) == true { locked = false }
    }
}
