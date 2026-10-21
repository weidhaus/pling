import EventKit
import ServiceManagement
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Servers", systemImage: "server.rack") { ServersSettings() }
            Tab("Notifications", systemImage: "bell.badge") { NotificationSettings() }
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 620)
    }
}

struct ServersSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var selection: UUID?
    @State private var adding = false
    @State private var confirmingDelete = false

    private var selected: Server? { servers.first { $0.id == selection } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text((app.connections.status[server.id] ?? .idle).label)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(server.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button("Add Server", systemImage: "plus") { adding = true; selection = nil }
                    Button("Remove Server", systemImage: "minus") { confirmingDelete = true }
                        .disabled(selected == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 190)

            Group {
                if adding || selected != nil {
                    ServerEditor(server: adding ? nil : selected) { saved in
                        adding = false
                        selection = saved.id
                    }
                } else {
                    ContentUnavailableView("No Server Selected", systemImage: "server.rack",
                                           description: Text("Add a server with the + button."))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(height: 400)
        .onAppear { selection = selection ?? servers.first?.id }
        .confirmationDialog("Remove “\(selected?.name ?? "")”?", isPresented: $confirmingDelete) {
            Button("Remove Server", role: .destructive, action: delete)
        } message: {
            Text("Its topics and messages are removed from this Mac. Nothing changes on the server.")
        }
    }

    private func delete() {
        guard let server = selected else { return }
        app.connections.stop(server.id)
        for sub in server.subscriptions {
            let id = sub.id
            try? context.delete(model: StoredMessage.self, where: #Predicate { $0.subscriptionID == id })
            Keychain.delete(sub.passphraseAccount)
        }
        Keychain.delete(server.secretAccount)
        app.selection = .all
        context.delete(server)
        try? context.save()
        selection = servers.first?.id
    }
}

struct NotificationSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Prefs.realertEnabled) private var realertEnabled = true
    @AppStorage(Prefs.realertMinutes) private var realertMinutes = 5
    @AppStorage(Prefs.realertMax) private var realertMax = 12
    @AppStorage(Prefs.tomorrowHour) private var tomorrowHour = 9
    @AppStorage(Prefs.remindersListID) private var remindersListID = ""
    @State private var lists: [EKCalendar] = []
    @State private var remindersAuthorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

    var body: some View {
        Form {
            Section {
                Toggle("Repeat high and urgent notifications until acknowledged", isOn: $realertEnabled)
                Picker("Repeat Every", selection: $realertMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!realertEnabled)
                Picker("Stop After", selection: $realertMax) {
                    ForEach([3, 6, 12, 24], id: \.self) { Text("\($0) times").tag($0) }
                }
                .disabled(!realertEnabled)
            } footer: {
                Text("Repeats replace the previous notification instead of piling up. Acknowledge from the notification or mark the message as read to stop them.")
                    .foregroundStyle(.secondary)
            }
            Section("Remind Me") {
                Picker("“Tomorrow” Means", selection: $tomorrowHour) {
                    ForEach(6...12, id: \.self) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!, format: .dateTime.hour().minute()).tag(h)
                    }
                }
                if remindersAuthorized {
                    Picker("Reminders List", selection: $remindersListID) {
                        Text("Default List").tag("")
                        ForEach(lists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                } else {
                    LabeledContent("Reminders") {
                        Button("Allow Access…") {
                            Task {
                                remindersAuthorized = (try? await app.eventStore.requestFullAccessToReminders()) ?? false
                                loadLists()
                            }
                        }
                    }
                }
            }
            Section {
                Button("Open Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                }
            } footer: {
                Text("Choose banner style, sounds and Focus behavior in System Settings.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
        .onAppear(perform: loadLists)
    }

    private func loadLists() {
        guard remindersAuthorized else { return }
        lists = app.eventStore.calendars(for: .reminder).sorted { $0.title < $1.title }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Prefs.retentionDays) private var retentionDays = 30
    @AppStorage(Prefs.doNotDisturb) private var doNotDisturb = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Pling at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                Toggle("Do Not Disturb", isOn: $doNotDisturb)
            } footer: {
                Text("Pling needs to be running to receive messages.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Keep Messages", selection: $retentionDays) {
                    Text("1 Week").tag(7)
                    Text("1 Month").tag(30)
                    Text("3 Months").tag(90)
                    Text("1 Year").tag(365)
                }
                .onChange(of: retentionDays) { app.connections.prune() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}
