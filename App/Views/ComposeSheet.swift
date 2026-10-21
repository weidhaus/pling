import PlingCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ComposeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.createdAt) private var servers: [Server]

    let initial: Subscription?

    enum Target: Hashable { case subscription(UUID), other }

    @State private var target: Target = .other
    @State private var otherServerID: UUID?
    @State private var otherTopic = ""
    @State private var title = ""
    @State private var message = ""
    @State private var markdown = false
    @State private var priority = 3
    @State private var tags = ""
    @State private var click = ""
    @State private var delay = ""
    @State private var file: URL?
    @State private var importing = false
    @State private var encrypt = false
    @State private var sending = false
    @State private var error: String?

    private var subscription: Subscription? {
        guard case let .subscription(id) = target else { return nil }
        return servers.lazy.flatMap(\.subscriptions).first { $0.id == id }
    }

    private var server: Server? { subscription?.server ?? servers.first { $0.id == otherServerID } }
    private var topic: String { subscription?.topic ?? otherTopic }
    private var tagList: [String] { tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var canSend: Bool {
        server != nil && topic.wholeMatch(of: /[-_A-Za-z0-9]{1,64}/) != nil && (!message.isEmpty || file != nil) && !sending
    }

    var body: some View {
        Form {
            Section {
                Picker("To", selection: $target) {
                    ForEach(servers) { server in
                        Section(server.name) {
                            ForEach(server.sortedSubscriptions) { sub in
                                Text([sub.emoji, sub.title].compactMap(\.self).joined(separator: " ")).tag(Target.subscription(sub.id))
                            }
                        }
                    }
                    Divider()
                    Text("Other Topic…").tag(Target.other)
                }
                if target == .other {
                    Picker("Server", selection: $otherServerID) {
                        ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Topic", text: $otherTopic, prompt: Text("topic-name"))
                        .autocorrectionDisabled()
                }
            }
            Section {
                TextField("Title", text: $title, prompt: Text("Optional"))
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 90)
                    .accessibilityLabel("Message")
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("Message").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                Toggle("Format as Markdown", isOn: $markdown)
            }
            Section {
                Picker("Priority", selection: $priority) {
                    ForEach(1...5, id: \.self) { p in
                        Text(PriorityStyle.name(p)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Tags") {
                    HStack {
                        TextField("Tags", text: $tags, prompt: Text("warning, backup"))
                            .labelsHidden()
                        let preview = Emoji.split(tagList).emoji.joined()
                        if !preview.isEmpty { Text(preview).accessibilityHidden(true) }
                    }
                }
                TextField("Link", text: $click, prompt: Text("Opens when the notification is clicked"))
                    .textContentType(.URL)
                Picker("Send", selection: $delay) {
                    Text("Now").tag("")
                    Text("In 15 Minutes").tag("15m")
                    Text("In 1 Hour").tag("1h")
                    Text("Tomorrow at 9:00").tag("tomorrow, 9am")
                }
            }
            Section {
                LabeledContent("Attachment") {
                    if let file {
                        HStack {
                            Label(file.lastPathComponent, systemImage: "paperclip").lineLimit(1).truncationMode(.middle)
                            Button("Remove", systemImage: "xmark.circle.fill") { self.file = nil }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    } else {
                        Button("Choose File…") { importing = true }
                    }
                }
                Toggle("Encrypt End-to-End", isOn: $encrypt)
                    .disabled(subscription?.hasPassphrase != true)
                    .help(subscription?.hasPassphrase == true ? "Only apps with this topic’s passphrase can read it." : "Set a passphrase for this topic first.")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("New Message")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { file = url }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Sending…" : "Send") { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .onAppear {
            otherServerID = servers.first?.id
            if let initial { target = .subscription(initial.id); encrypt = initial.hasPassphrase }
            else if let first = servers.first?.sortedSubscriptions.first { target = .subscription(first.id) }
        }
        .onChange(of: target) { encrypt = subscription?.hasPassphrase == true }
    }

    private func send() async {
        guard let server else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            var request = PublishRequest(topic: topic)
            request.priority = priority == 3 ? nil : priority
            request.delay = delay.isEmpty ? nil : delay
            var fileData: Data?
            if let file {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                fileData = try Data(contentsOf: file)
            }
            let clickURL = URL(string: click.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }

            if encrypt {
                // Fail closed: never fall back to plaintext when the user asked for encryption.
                guard let key = subscription.flatMap({ app.connections.key(for: $0) }) else {
                    error = "Couldn’t read this topic’s passphrase from the Keychain. Re-enter it in Topic Settings."
                    return
                }
                var payload = E2EPayload(title: title.isEmpty ? nil : title, message: message, tags: tagList,
                                         priority: priority, click: clickURL, markdown: markdown)
                if let file, let fileData {
                    let sealed = try E2E.sealData(fileData, key: key)
                    payload.attachment = E2EAttachmentInfo(name: file.lastPathComponent, type: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType,
                                                           sha256: E2E.digest(sealed))
                    request.attachment = .init(data: sealed, filename: "attachment.bin")
                }
                request.title = E2E.encryptedTitle
                request.message = try E2E.seal(payload, key: key)
            } else {
                request.title = title.isEmpty ? nil : title
                request.message = message.isEmpty ? nil : message
                request.tags = tagList
                request.click = clickURL
                request.markdown = markdown
                if let file, let fileData { request.attachment = .init(data: fileData, filename: file.lastPathComponent) }
            }
            _ = try await server.client.publish(request)
            dismiss()
        } catch E2E.Failure.tooLarge {
            error = "This message is too long to encrypt. Shorten it to under about 2,000 characters."
        } catch {
            self.error = ServerEditor.describe(error)
        }
    }
}
