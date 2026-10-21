import SwiftData
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \Server.createdAt) private var servers: [Server]
    @State private var search = ""

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView(servers: servers)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            if servers.isEmpty {
                NoServersView()
            } else {
                MessageList(item: app.selection ?? .all, search: search)
                    .safeAreaInset(edge: .top, spacing: 0) { NotificationsOffBanner() }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Messages")
        .sheet(isPresented: $app.isComposing) { ComposeSheet(initial: app.composeTopic) }
        .sheet(isPresented: $app.isAddingTopic) { TopicEditor(subscription: nil) }
        .sheet(item: $app.editingTopic) { TopicEditor(subscription: $0) }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    let servers: [Server]
    @Query(filter: #Predicate<StoredMessage> { !$0.isRead }) private var unread: [StoredMessage]

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                Label("All Messages", systemImage: "tray.full").tag(SidebarItem.all)
                Label("Unread", systemImage: "envelope.badge")
                    .badge(unread.count)
                    .tag(SidebarItem.unread)
                Label("Important", systemImage: "exclamationmark.circle")
                    .badge(unread.filter { $0.priority >= 4 }.count)
                    .tag(SidebarItem.important)
            }
            ForEach(servers) { server in
                Section {
                    ForEach(server.sortedSubscriptions) { sub in
                        TopicRow(subscription: sub, unread: unread.filter { $0.subscriptionID == sub.id }.count)
                            .tag(SidebarItem.topic(sub.id))
                    }
                } header: {
                    ServerHeader(server: server)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !servers.isEmpty {
                Button("Add Topic", systemImage: "plus") { app.isAddingTopic = true }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ServerHeader: View {
    @Environment(AppModel.self) private var app
    let server: Server

    var body: some View {
        let status = app.connections.status[server.id] ?? .idle
        HStack(spacing: 6) {
            Text(server.name)
            Circle()
                .fill(color(status))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .help(status.label)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.label)
    }

    private func color(_ s: ConnectionStatus) -> Color {
        switch s {
        case .connected: .green
        case .connecting, .idle: .yellow
        case .unauthorized, .failed: .red
        }
    }
}

struct TopicRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    let subscription: Subscription
    let unread: Int
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(subscription.title)
                if subscription.isMuted {
                    Image(systemName: "bell.slash").foregroundStyle(.secondary).font(.caption)
                        .accessibilityLabel("Muted")
                }
                if subscription.hasPassphrase {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption2)
                        .accessibilityLabel("Encrypted")
                }
            }
        } icon: {
            if let emoji = subscription.emoji, !emoji.isEmpty { Text(emoji) } else { Image(systemName: "number") }
        }
        .badge(unread)
        .contextMenu {
            Button("New Message…") { app.compose(to: subscription) }
            Button("Mark All as Read") { app.markAllRead(app.messages(for: .topic(subscription.id))) }
            Menu("Mute") {
                Button("For 1 Hour") { mute(3600) }
                Button("For 8 Hours") { mute(8 * 3600) }
                Button("Until Tomorrow Morning") { subscription.mutedUntil = AppModel.SnoozeOption.tomorrow.date }
                Button("Until I Unmute") { subscription.mutedUntil = .distantFuture }
            }
            if subscription.isMuted { Button("Unmute") { subscription.mutedUntil = nil } }
            Divider()
            Button("Edit Topic…") { editing = true }
            Button("Unsubscribe…", role: .destructive) { confirmingDelete = true }
        }
        .sheet(isPresented: $editing) { TopicEditor(subscription: subscription) }
        .confirmationDialog("Unsubscribe from “\(subscription.title)”?", isPresented: $confirmingDelete) {
            Button("Unsubscribe", role: .destructive) { unsubscribe() }
        } message: {
            Text("Its messages are removed from this Mac. The topic on the server isn’t affected.")
        }
    }

    private func mute(_ seconds: TimeInterval) { subscription.mutedUntil = .now.addingTimeInterval(seconds) }

    private func unsubscribe() {
        let id = subscription.id
        let server = subscription.server
        try? context.delete(model: StoredMessage.self, where: #Predicate { $0.subscriptionID == id })
        Keychain.delete(subscription.passphraseAccount)
        if app.selection == .topic(id) { app.selection = .all }
        context.delete(subscription)
        try? context.save()
        if let server { app.connections.connect(server) }
    }
}

struct MessageList: View {
    @Environment(AppModel.self) private var app
    @Query private var messages: [StoredMessage]
    @Query private var subscriptions: [Subscription]
    let item: SidebarItem
    let search: String

    init(item: SidebarItem, search: String) {
        self.item = item
        self.search = search
        let filter: Predicate<StoredMessage>?
        switch item {
        case .all: filter = nil
        case .unread: filter = #Predicate<StoredMessage> { !$0.isRead }
        case .important: filter = #Predicate<StoredMessage> { $0.priority >= 4 }
        case let .topic(id): filter = #Predicate<StoredMessage> { $0.subscriptionID == id }
        }
        _messages = Query(filter: filter, sort: [SortDescriptor(\.time, order: .reverse), SortDescriptor(\.receivedAt, order: .reverse)])
    }

    private var visible: [StoredMessage] {
        guard !search.isEmpty else { return messages }
        return messages.filter {
            $0.title.localizedStandardContains(search) || $0.body.localizedStandardContains(search)
                || $0.tags.contains { $0.localizedStandardContains(search) }
        }
    }

    private var days: [(day: Date, messages: [StoredMessage])] {
        Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.time) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    private var currentSubscription: Subscription? {
        if case let .topic(id) = item { subscriptions.first { $0.id == id } } else { nil }
    }

    var body: some View {
        let lookup = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        ScrollViewReader { proxy in
            List {
                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.messages) { m in
                            MessageRow(message: m, subscription: lookup[m.subscriptionID], showsTopic: currentSubscription == nil)
                                .id(m.key)
                                .listRowBackground(app.highlightedKey == m.key ? Color.accentColor.opacity(0.12) : nil)
                        }
                    } header: {
                        DayHeader(day: day.day)
                    }
                }
            }
            .listStyle(.inset)
            .overlay { if visible.isEmpty { emptyState } }
            .onChange(of: app.highlightedKey, initial: true) { _, key in
                guard let key else { return }
                withAnimation { proxy.scrollTo(key, anchor: .center) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Mark All as Read", systemImage: "envelope.open") { app.markAllRead(visible) }
                    .disabled(!visible.contains { !$0.isRead })
            }
            if let sub = currentSubscription {
                ToolbarItem {
                    Button("Topic Settings", systemImage: "slider.horizontal.3") { app.editTopic(sub) }
                        .help("Topic Settings: name, notifications, encryption passphrase")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Message", systemImage: "square.and.pencil") { app.compose(to: currentSubscription) }
            }
        }
    }

    private var title: String {
        switch item {
        case .all: "All Messages"
        case .unread: "Unread"
        case .important: "Important"
        case .topic: currentSubscription?.title ?? "Topic"
        }
    }

    private var subtitle: String {
        let unread = visible.filter { !$0.isRead }.count
        if let sub = currentSubscription, let server = sub.server {
            return "\(server.name) · \(sub.topic)" + (unread > 0 ? " · \(unread) unread" : "")
        }
        return unread > 0 ? "\(unread) unread" : ""
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch item {
            case .unread:
                ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle", description: Text("You’ve read every message."))
            case .important:
                ContentUnavailableView("Nothing Urgent", systemImage: "exclamationmark.circle", description: Text("High and urgent priority messages appear here."))
            default:
                ContentUnavailableView {
                    Label("No Messages Yet", systemImage: "bell")
                } description: {
                    Text("Messages published to your topics appear here.")
                } actions: {
                    Button("New Message…") { app.compose(to: currentSubscription) }
                }
            }
        }
    }
}

/// Shown when macOS has notifications turned off for Pling.
struct NotificationsOffBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.notificationStatus == .denied {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                Text("Notifications are turned off for Pling, so new messages only appear here.")
                    .font(.callout)
                Spacer()
                Button("Turn On…") { app.openNotificationSettings() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
    }
}

struct DayHeader: View {
    let day: Date
    var body: some View {
        Group {
            if Calendar.current.isDateInToday(day) { Text("Today") }
            else if Calendar.current.isDateInYesterday(day) { Text("Yesterday") }
            else { Text(day, format: .dateTime.weekday(.wide).month(.wide).day()) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}
