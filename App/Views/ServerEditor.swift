import PlingCore
import SwiftData
import SwiftUI

/// Create (server == nil) or edit a server. Secrets go to the Keychain.
struct ServerEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    let server: Server?
    var onSave: (Server) -> Void = { _ in }

    @State private var name = ""
    @State private var urlText = ""
    @State private var authKind = AuthKind.basic
    @State private var username = ""
    @State private var secret = ""
    @State private var relayText = ""
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    private var url: URL? {
        var text = urlText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil, ["http", "https"].contains(url.scheme) else { return nil }
        return url
    }

    private var relayURL: URL? {
        guard !relayText.isEmpty, let url = URL(string: relayText.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    private var hasStoredSecret: Bool { server.map { Keychain.get($0.secretAccount) != nil } ?? false }

    private var canSave: Bool {
        guard url != nil else { return false }
        switch authKind {
        case .none: return true
        case .basic: return !username.isEmpty && (!secret.isEmpty || hasStoredSecret)
        case .token: return !secret.isEmpty || hasStoredSecret
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $urlText, prompt: Text("https://ntfy.sh"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Name", text: $name, prompt: Text(url?.host() ?? "My Server"))
            }
            Section("Sign In") {
                Picker("Authentication", selection: $authKind) {
                    ForEach(AuthKind.allCases) { Text($0.label).tag($0) }
                }
                switch authKind {
                case .none:
                    EmptyView()
                case .basic:
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $secret, prompt: Text(hasStoredSecret ? "Saved in Keychain" : "Required"))
                        .textContentType(.password)
                case .token:
                    SecureField("Token", text: $secret, prompt: Text(hasStoredSecret ? "Saved in Keychain" : "tk_…"))
                }
            }
            #if os(iOS)
            Section {
                TextField("Push Relay", text: $relayText, prompt: Text("https://push.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Push Notifications")
            } footer: {
                Text("iOS only delivers messages to Pling in the background through a pling-relay running next to your server. Without one, messages arrive while Pling is open.")
            }
            #endif
            Section {
                HStack {
                    Button("Test Connection") { Task { await test() } }
                        #if os(iOS)
                        .buttonStyle(.borderless)
                        #endif
                        .disabled(url == nil || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(server == nil ? "Add Server" : "Save") { save() }
                        #if os(iOS)
                        .disabled(relayText.isEmpty == false && relayURL == nil)
                        #endif
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
                switch testResult {
                case let .success(text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case let .failure(error):
                    Label(Self.describe(error), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: server?.id) { load() }
    }

    private func load() {
        testResult = nil
        secret = ""
        guard let server else { return }
        name = server.name
        urlText = server.url.absoluteString
        authKind = server.authKind
        username = server.username ?? ""
        relayText = server.relayURL?.absoluteString ?? ""
    }

    private var draftAuth: NtfyAuth {
        let stored = server.flatMap { Keychain.get($0.secretAccount) } ?? ""
        let s = secret.isEmpty ? stored : secret
        switch authKind {
        case .none: return .none
        case .basic: return .basic(user: username, password: s)
        case .token: return .token(s)
        }
    }

    private func test() async {
        guard let url else { return }
        testing = true
        defer { testing = false }
        do {
            let data = try await NtfyClient(baseURL: url, auth: draftAuth).fetch(url.appending(path: "v1/account"))
            let user = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["username"] as? String
            testResult = .success(user.map { $0 == "*" ? "Connected without signing in" : "Signed in as \($0)" } ?? "Connected")
        } catch {
            testResult = .failure(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case NtfyClient.Failure.unauthorized: "The username, password or token was rejected."
        case let NtfyClient.Failure.http(code): "The server answered with HTTP \(code). Is this an ntfy server?"
        default: error.localizedDescription
        }
    }

    private func save() {
        guard let url else { return }
        let target = server ?? Server(name: "", url: url)
        if server == nil { context.insert(target) }
        target.name = name.isEmpty ? (url.host() ?? "Server") : name
        if target.url != url { target.lastMessageID = nil }
        target.url = url
        target.authKind = authKind
        target.username = authKind == .basic ? username : nil
        #if os(iOS)
        target.relayURL = relayURL
        #endif
        if authKind == .none { Keychain.delete(target.secretAccount) } else if !secret.isEmpty { Keychain.set(secret, for: target.secretAccount) }
        try? context.save()
        secret = ""
        app.connections.connect(target)
        onSave(target)
    }
}

#if os(macOS)
struct NoServersView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("Connect to an ntfy server to start receiving messages.")
        } actions: {
            Button("Set Up Pling…") { openWindow(id: "onboarding") }
                .buttonStyle(.borderedProminent)
        }
    }
}
#endif
