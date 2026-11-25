import SwiftUI

struct SignInView: View {
    @Environment(Store.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var err: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                } footer: {
                    if let err { Text(err).foregroundStyle(.red) } else { Text("Then the 6-digit code from your authenticator app.") }
                }
                Section {
                    Button { go() } label: {
                        HStack { Text("Sign in"); if busy { Spacer(); ProgressView() } }
                    }.disabled(email.isEmpty || password.isEmpty || busy)
                }
            }
            .navigationTitle("Money")
            .onSubmit { go() }
        }
    }

    private func go() {
        guard !email.isEmpty, !password.isEmpty, !busy else { return }
        busy = true; err = nil
        Task {
            do { try await store.signIn(email.trimmingCharacters(in: .whitespaces), password); password = "" }
            catch { err = "That didn't work. Check the email and password." }
            busy = false
        }
    }
}

struct CodeView: View {
    @Environment(Store.self) private var store
    let factorId: String
    @State private var code = ""
    @State private var err: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-digit code", text: $code)
                        .textContentType(.oneTimeCode).keyboardType(.numberPad)
                        .font(.title2.monospacedDigit()).focused($focused)
                        .onChange(of: code) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(6))
                            if digits != v { code = digits }
                            if digits.count == 6 { go() }
                        }
                } header: { Text("Authenticator code") } footer: {
                    if let err { Text(err).foregroundStyle(.red) } else { Text("Open your authenticator app and type the code for Money.") }
                }
                Section {
                    Button { go() } label: { HStack { Text("Continue"); if busy { Spacer(); ProgressView() } } }
                        .disabled(code.count != 6 || busy)
                    Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                }
            }
            .navigationTitle("One more step")
            .onAppear { focused = true }
        }
    }

    private func go() {
        guard code.count == 6, !busy else { return }
        busy = true; err = nil
        Task {
            do { try await store.verify(factorId, code) }
            catch { err = "That code didn't work. Wait for the next one and try again."; code = "" }
            busy = false
        }
    }
}

struct EnrollView: View {
    @Environment(Store.self) private var store
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This account has no authenticator app set up yet. Set it up once on the website, then come back here.")
                    Link("Open the website", destination: URL(string: "https://santiagocast2006-cpu.github.io/money/")!)
                }
                Section {
                    Button("I've set it up") { Task { await store.start() } }
                    Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                }
            }
            .navigationTitle("Authenticator")
        }
    }
}
