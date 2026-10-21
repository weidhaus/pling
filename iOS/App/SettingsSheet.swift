import SwiftData
import SwiftUI

struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(PushRegistrar.self) private var push
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @AppStorage(Prefs.doNotDisturb) private var doNotDisturb = false
    @AppStorage(Prefs.realertEnabled) private var realertEnabled = true
    @AppStorage(Prefs.realertMinutes) private var realertMinutes = 5
    @AppStorage(Prefs.tomorrowHour) private var tomorrowHour = 9
    @AppStorage(Prefs.retentionDays) private var retentionDays = 30
    @State private var removing: Server?

    var body: some View {
        NavigationStack {
            Form {
                Section("Servers") {
                    ForEach(servers) { server in
                        NavigationLink {
                            ServerEditor(server: server).navigationTitle(server.name)
                        } label: {
                            ServerStatusRow(server: server)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = server }
                        }
                    }
                    NavigationLink("Add Server") {
                        ServerEditor(server: nil).navigationTitle("Add Server")
                    }
                }
                Section {
                    Toggle("Do Not Disturb", isOn: $doNotDisturb)
                        .onChange(of: doNotDisturb) { push.scheduleSync() }
                } footer: {
                    Text("Messages still arrive in Pling, without notifications.")
                }
                Section {
                    Toggle("Repeat High and Urgent", isOn: $realertEnabled)
                    Picker("Repeat Every", selection: $realertMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .disabled(!realertEnabled)
                } header: {
                    Text("Urgent Messages")
                } footer: {
                    Text("Repeats happen while Pling is open, until you mark the message as read.")
                }
                Section("Remind Me") {
                    Picker("“Tomorrow” Means", selection: $tomorrowHour) {
                        ForEach(6...12, id: \.self) { h in
                            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)!, format: .dateTime.hour().minute()).tag(h)
                        }
                    }
                }
                Section {
                    Picker("Keep Messages", selection: $retentionDays) {
                        Text("1 Week").tag(7)
                        Text("1 Month").tag(30)
                        Text("3 Months").tag(90)
                        Text("1 Year").tag(365)
                    }
                    .onChange(of: retentionDays) { app.connections.prune() }
                    Button("Notification Settings") { app.openNotificationSettings() }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Source Code", destination: URL(string: "https://github.com/weidhaus/pling")!)
                } footer: {
                    Text("Pling is an independent project and isn’t affiliated with ntfy.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove Server", role: .destructive) { if let removing { app.remove(removing) } }
            } message: {
                Text("Its topics and messages are removed from this \(Platform.deviceName). Nothing changes on the server.")
            }
        }
    }
}

struct ServerStatusRow: View {
    @Environment(AppModel.self) private var app
    @Environment(PushRegistrar.self) private var push
    let server: Server

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.name)
            Group {
                switch push.status[server.id] {
                case _ where server.subscriptions.isEmpty:
                    Text("Add a topic to get notifications")
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .success:
                    Label("Push notifications on", systemImage: "bell.fill")
                case nil:
                    Text(server.relayURL == nil ? "Messages arrive while Pling is open" : "Setting up push…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }
}
