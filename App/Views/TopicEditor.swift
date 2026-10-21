import SwiftData
import SwiftUI

/// Add a topic (subscription == nil) or edit an existing one.
struct TopicEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.createdAt) private var servers: [Server]

    let subscription: Subscription?

    @State private var serverID: UUID?
    @State private var topic = ""
    @State private var displayName = ""
    @State private var emoji = ""
    @State private var minPriority = 1
    @State private var passphrase = ""
    @State private var removePassphrase = false

    private var isNew: Bool { subscription == nil }
    private var topicIsValid: Bool { topic.wholeMatch(of: /[-_A-Za-z0-9]{1,64}/) != nil }
    private var duplicate: Bool {
        isNew && servers.first { $0.id == serverID }?.subscriptions.contains { $0.topic == topic } == true
    }

    var body: some View {
        Form {
            Section {
                if isNew {
                    Picker("Server", selection: $serverID) {
                        ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("Topic", text: $topic, prompt: Text("backups"))
                        .textContentType(.none)
                        .autocorrectionDisabled()
                } else {
                    LabeledContent("Topic", value: subscription!.topic)
                }
            } footer: {
                if !topic.isEmpty, !topicIsValid {
                    Text("Use letters, numbers, dashes and underscores, up to 64 characters.").foregroundStyle(.red)
                } else if duplicate {
                    Text("You’re already subscribed to this topic.").foregroundStyle(.red)
                }
            }
            Section("Appearance") {
                TextField("Display Name", text: $displayName, prompt: Text(topic.isEmpty ? "Optional" : topic))
                TextField("Emoji", text: $emoji, prompt: Text("Optional"))
                    .onChange(of: emoji) { _, new in if new.count > 1 { emoji = String(new.suffix(1)) } }
            }
            Section("Notifications") {
                Picker("Notify For", selection: $minPriority) {
                    Text("All Messages").tag(1)
                    Text("Low Priority and Above").tag(2)
                    Text("Default Priority and Above").tag(3)
                    Text("High and Urgent Only").tag(4)
                    Text("Urgent Only").tag(5)
                }
            }
            Section {
                SecureField("Passphrase", text: $passphrase,
                            prompt: Text(subscription?.hasPassphrase == true ? "Unchanged" : "None"))
                if subscription?.hasPassphrase == true {
                    Toggle("Remove Passphrase", isOn: $removePassphrase)
                }
            } header: {
                Text("End-to-End Encryption")
            } footer: {
                Text("Messages sent from Pling or the ntfy-e2e tool are encrypted with this passphrase. Everyone on this topic needs the same one. It’s stored in your Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(isNew ? "Add Topic" : "Edit Topic")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add Topic" : "Save") { save() }
                    .disabled(isNew && (!topicIsValid || duplicate || serverID == nil))
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let s = subscription {
            topic = s.topic; displayName = s.displayName ?? ""; emoji = s.emoji ?? ""; minPriority = s.minPriority
            serverID = s.server?.id
        } else {
            serverID = servers.first?.id
        }
    }

    private func save() {
        let sub: Subscription
        if let subscription {
            sub = subscription
        } else {
            guard let server = servers.first(where: { $0.id == serverID }) else { return }
            sub = Subscription(topic: topic, server: server)
            context.insert(sub)
        }
        sub.displayName = displayName.isEmpty ? nil : displayName
        sub.emoji = emoji.isEmpty ? nil : emoji
        sub.minPriority = minPriority

        var passphraseChanged = false
        if removePassphrase {
            Keychain.delete(sub.passphraseAccount); sub.hasPassphrase = false; passphraseChanged = true
        } else if !passphrase.isEmpty {
            Keychain.set(passphrase, for: sub.passphraseAccount); sub.hasPassphrase = true; passphraseChanged = true
        }
        try? context.save()
        if passphraseChanged { app.connections.passphraseChanged(sub) }

        if isNew, let server = sub.server {
            app.connections.connect(server)
            app.selection = .topic(sub.id)
            Task {
                await app.notifier.requestAuthorization()
                await app.connections.backfill(sub)
            }
        }
        dismiss()
    }
}
