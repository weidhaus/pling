import SwiftData
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Query(sort: [SortDescriptor(\StoredMessage.time, order: .reverse), SortDescriptor(\StoredMessage.receivedAt, order: .reverse)])
    private var messages: [StoredMessage]
    @Query private var subscriptions: [Subscription]
    @AppStorage(Prefs.doNotDisturb) private var doNotDisturb = false

    private var recent: ArraySlice<StoredMessage> { messages.prefix(60) }
    private var unreadCount: Int { messages.lazy.filter { !$0.isRead }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(height: 440)
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Pling").font(.title3.weight(.semibold))
            if doNotDisturb {
                Label("Do Not Disturb", systemImage: "moon.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if unreadCount > 0 {
                Text("\(unreadCount) unread").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Mark All as Read", systemImage: "envelope.open") { app.markAllRead(Array(messages)) }
                .labelStyle(.iconOnly)
                .disabled(unreadCount == 0)
                .help("Mark All as Read")
            Menu("More", systemImage: "ellipsis.circle") {
                Toggle("Do Not Disturb", isOn: $doNotDisturb)
                Divider()
                Button("Settings…") { openSettings(); NSApp.activate() }
                Button("Check for Updates…") { app.updater.checkForUpdates(nil) }
                Button("Quit Pling") { NSApp.terminate(nil) }
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        if subscriptions.isEmpty {
            ContentUnavailableView {
                Label("Welcome to Pling", systemImage: "bell.badge")
            } description: {
                Text("Connect your ntfy server and subscribe to a topic.")
            } actions: {
                Button("Set Up Pling…") { app.showMainWindow() }
                    .buttonStyle(.borderedProminent)
            }
        } else if recent.isEmpty {
            ContentUnavailableView("No Messages Yet", systemImage: "bell",
                                   description: Text("New notifications from your topics appear here."))
        } else {
            let lookup = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { m in
                        MessageRow(message: m, subscription: lookup[m.subscriptionID], compact: true)
                        Divider().padding(.leading, 25)
                    }
                }
            }
        }
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button("New Message", systemImage: "square.and.pencil") { app.compose() }
                    .buttonStyle(.glassProminent)
                Spacer()
                Button { app.showMainWindow() } label: {
                    Label("Open Pling", systemImage: "macwindow")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .disabled(subscriptions.isEmpty)
        }
        .padding(10)
    }
}
