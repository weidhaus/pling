import EventKit
import ServiceManagement
import SwiftData
import SwiftUI

/// First-run setup: server → topics → notifications → Reminders → done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, server, topics, notifications, reminders, done }

    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var step = Step.welcome

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(count: Step.allCases.count, current: step.rawValue)
                .padding(.top, 22)
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .server: ServerStep()
                case .topics: TopicsStep()
                case .notifications: NotificationsStep()
                case .reminders: RemindersStep()
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            footer
        }
        .frame(width: 580, height: 640)
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
    }

    private var footer: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") { go(-1) }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { go(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .server:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).disabled(servers.isEmpty)
            case .topics:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent)
                    .disabled(!servers.contains { !$0.subscriptions.isEmpty })
            case .notifications, .reminders:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .done:
                Button("Open Pling") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(20)
    }

    private func go(_ delta: Int) {
        withAnimation(.smooth(duration: 0.35)) { step = Step(rawValue: step.rawValue + delta) ?? step }
    }

    private func finish() {
        Prefs.defaults.set(true, forKey: Prefs.onboarded)
        dismissWindow(id: "onboarding")
        app.showMainWindow()
    }
}

private struct ProgressDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == current ? 20 : 7, height: 7)
            }
        }
        .animation(.smooth, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Icon, title and one-line explanation shared by every step.
private struct StepHeader: View {
    let symbol: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(height: 52)
                    .accessibilityHidden(true)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
            }
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 26)
        .padding(.bottom, 20)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: nil, title: "Welcome to Pling", subtitle: "Your ntfy notifications, at home on your Mac.")
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "menubar.arrow.up.rectangle", title: "Always within reach",
                        text: "Pling lives in your menu bar and keeps every message in one searchable inbox.")
                Feature(symbol: "exclamationmark.2", title: "Never miss what matters",
                        text: "Urgent messages repeat until you acknowledge them. Snooze anything, or send it to Reminders.")
                Feature(symbol: "lock.shield", title: "Private when it counts",
                        text: "Encrypt a topic end to end, so even your server can’t read it.")
            }
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    struct Feature: View {
        let symbol: String, title: String, text: String
        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ServerStep: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var addingAnother = false

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "server.rack", title: "Connect Your Server",
                       subtitle: "Use ntfy.sh or your own ntfy server. Passwords and tokens are kept in your Keychain.")
            if servers.isEmpty || addingAnother {
                ServerEditor(server: nil) { _ in addingAnother = false }
                    .scrollDisabled(true)
            } else {
                VStack(spacing: 10) {
                    ForEach(servers) { server in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text(server.name).font(.headline)
                                Text(server.url.absoluteString).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                    }
                    Button("Add Another Server", systemImage: "plus") { addingAnother = true }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }
    }
}

private struct TopicsStep: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var topic = ""
    @State private var serverID: UUID?

    private var server: Server? { servers.first { $0.id == serverID } ?? servers.first }
    private var canAdd: Bool {
        AppModel.isValidTopic(topic) && server?.subscriptions.contains { $0.topic == topic } == false
    }

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "number", title: "Subscribe to Topics",
                       subtitle: "Topics are the channels you publish to, like “backups” or “home-alerts”.")
            Form {
                Section {
                    if servers.count > 1 {
                        Picker("Server", selection: $serverID) {
                            ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    HStack {
                        TextField("Topic", text: $topic, prompt: Text("backups"))
                            .autocorrectionDisabled()
                            .onSubmit(add)
                        Button("Add", action: add).disabled(!canAdd)
                    }
                } footer: {
                    if !topic.isEmpty, !AppModel.isValidTopic(topic) {
                        Text("Use letters, numbers, dashes and underscores.").foregroundStyle(.red)
                    }
                }
                if let server, !server.subscriptions.isEmpty {
                    Section("Subscribed on \(server.name)") {
                        ForEach(server.sortedSubscriptions) { sub in
                            Label(sub.topic, systemImage: "number")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { serverID = serverID ?? servers.first?.id }
    }

    private func add() {
        guard canAdd, let server else { return }
        app.subscribe(to: topic, on: server)
        topic = ""
    }
}

private struct NotificationsStep: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "bell.badge", title: "Turn On Notifications",
                       subtitle: "Pling shows a banner for each new message. High and urgent ones repeat until you acknowledge them.")
            switch app.notificationStatus {
            case .authorized, .provisional, .ephemeral:
                Label("Notifications are on", systemImage: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(.green)
            case .denied:
                VStack(spacing: 12) {
                    Text("Notifications are turned off for Pling. Turn on “Allow notifications” in System Settings, then come back.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open Notification Settings…") { app.openNotificationSettings() }
                        .controlSize(.large)
                }
            default:
                Button("Allow Notifications") { Task { await app.requestNotifications() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
            }
            Spacer()
        }
        .task { await app.refreshNotificationStatus() }
    }
}

private struct RemindersStep: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Prefs.remindersListID) private var listID = ""
    @State private var authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @State private var denied = EKEventStore.authorizationStatus(for: .reminder) == .denied

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "checklist", title: "Send Messages to Reminders",
                       subtitle: "Optional. Turn any message into a reminder so it doesn’t get lost.")
            if authorized {
                Form {
                    Picker("Add Reminders To", selection: $listID) {
                        Text("Default List").tag("")
                        ForEach(app.reminderLists, id: \.calendarIdentifier) { list in
                            Label {
                                Text(list.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Color(cgColor: list.cgColor))
                            }
                            .tag(list.calendarIdentifier)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: 80)
            } else if denied {
                Text("Pling can’t access Reminders. You can allow it later in System Settings › Privacy & Security › Reminders.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Button("Allow Access to Reminders") {
                    Task {
                        authorized = await app.requestReminders()
                        denied = !authorized
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
            }
            Spacer()
        }
    }
}

private struct DoneStep: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(symbol: "checkmark.seal.fill", title: "You’re All Set",
                       subtitle: "Pling keeps running in your menu bar to receive messages.")
            VStack(alignment: .leading, spacing: 14) {
                Tip(symbol: "menubar.rectangle", text: "Click the **P** in your menu bar to see recent messages. A dot means unread.")
                Tip(symbol: "square.and.pencil", text: "Press **⌘N** to send a message to any topic.")
                Tip(symbol: "cursorarrow.click.2", text: "Right-click a message to snooze it or add it to Reminders.")
            }
            .padding(.horizontal, 20)
            Toggle("Open Pling at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .padding(.top, 26)
                .onChange(of: launchAtLogin) { _, on in
                    _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Spacer()
        }
    }

    struct Tip: View {
        let symbol: String
        let text: LocalizedStringKey
        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
                Text(text)
            }
        }
    }
}
