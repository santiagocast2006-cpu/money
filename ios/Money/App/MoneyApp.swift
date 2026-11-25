import SwiftUI

@main
struct MoneyApp: App {
    @State private var store = Store()
    @State private var lock = Lock()

    var body: some Scene {
        WindowGroup {
            Root().environment(store).environment(lock).tint(Color.accentColor)
        }
    }
}

struct Root: View {
    @Environment(Store.self) private var store
    @Environment(Lock.self) private var lock
    @Environment(\.scenePhase) private var phase
    @State private var cameFromBackground = false

    var body: some View {
        ZStack {
            switch store.step {
            case .checking: ProgressView()
            case .signIn: SignInView()
            case .code(let f): CodeView(factorId: f)
            case .enroll: EnrollView()
            case .ready: MainTabs()
            }
            // Face ID on every return, and a blank cover in the app switcher.
            if (store.step == .ready && lock.locked) || phase != .active { Cover() }
        }
        .task { await store.start() }
        .onChange(of: store.step) { old, new in
            guard new == .ready else { return }
            if store.usingFixture { lock.locked = false; return }
            if old == .checking { Task { await lock.unlock() } } else { lock.locked = false }
        }
        .onChange(of: phase) { _, p in
            if p == .background { lock.locked = true; cameFromBackground = true }
            if p == .active && cameFromBackground {
                cameFromBackground = false
                Task {
                    if store.step == .ready { await lock.unlock() }
                    await store.refreshIfStale()
                }
            }
        }
    }
}

struct Cover: View {
    @Environment(Lock.self) private var lock
    @Environment(Store.self) private var store
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "dollarsign.circle.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
                Text("Money").font(.title2.weight(.semibold))
                if lock.locked && store.step == .ready && !lock.busy {
                    Button { Task { await lock.unlock() } } label: { Label("Unlock", systemImage: "faceid") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
