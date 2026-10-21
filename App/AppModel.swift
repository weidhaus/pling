import AppKit
import EventKit
import PlingCore
import ServiceManagement
import SwiftData
import Sparkle
import SwiftUI
import UserNotifications

enum SidebarItem: Hashable {
    case all, unread, important
    case topic(UUID)

    func includes(_ m: StoredMessage) -> Bool {
        switch self {
        case .all: true
        case .unread: !m.isRead
        case .important: m.priority >= 4
        case let .topic(id): m.subscriptionID == id
        }
    }
}

/// App-wide coordinator: connections, notifications, re-alerts, snoozes, Reminders, attachments.
@Observable final class AppModel {
    var selection: SidebarItem? = .all
    var highlightedKey: String?
    var composeTopic: Subscription?
    var isComposing = false
    var isAddingTopic = false
    var editingTopic: Subscription?
    var notificationStatus = UNAuthorizationStatus.notDetermined

    let context: ModelContext
    @ObservationIgnored private(set) var connections: ConnectionManager!
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private(set) var eventStore = EKEventStore()
    #if DEBUG
    @ObservationIgnored let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    @ObservationIgnored let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var alertLoop: Task<Void, Never>?
    @ObservationIgnored private let imageCache = NSCache<NSString, NSData>()

    init(context: ModelContext) {
        self.context = context
        connections = ConnectionManager(context: context) { [weak self] m, sub in self?.handleNew(m, subscription: sub) }
        notifier.onResponse = { [weak self] action, key in self?.handleNotification(action: action, key: key) }
    }

    func start() {
        Prefs.register()
        #if DEBUG
        seedFromEnvironment()
        #endif
        if !Prefs.defaults.bool(forKey: "didLaunchBefore") {
            Prefs.defaults.set(true, forKey: "didLaunchBefore")
            try? SMAppService.mainApp.register()
        }
        connections.start()
        alertLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fireDueAlerts()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        Task {
            await refreshNotificationStatus()
            // Users who finished onboarding before it asked for permission get asked once now.
            if Prefs.defaults.bool(forKey: Prefs.onboarded), notificationStatus == .notDetermined { await requestNotifications() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshNotificationStatus() } }
        }
    }

    func refreshNotificationStatus() async {
        notificationStatus = await notifier.authorizationStatus()
    }

    func requestNotifications() async {
        await notifier.requestAuthorization()
        await refreshNotificationStatus()
    }

    func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
    }

    var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Asks for Reminders access. A store created before access was granted can't see lists, so start a fresh one.
    func requestReminders() async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        if granted { eventStore = EKEventStore() }
        return granted
    }

    var reminderLists: [EKCalendar] {
        remindersAuthorized ? eventStore.calendars(for: .reminder).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : []
    }

    /// Adds a topic, reconnects its server and loads the server's cached messages.
    @discardableResult func subscribe(to topic: String, on server: Server) -> Subscription {
        let sub = Subscription(topic: topic, server: server)
        context.insert(sub)
        try? context.save()
        connections.connect(server)
        Task { await connections.backfill(sub) }
        return sub
    }

    static func isValidTopic(_ topic: String) -> Bool { topic.wholeMatch(of: /[-_A-Za-z0-9]{1,64}/) != nil }

    func editTopic(_ subscription: Subscription) {
        editingTopic = subscription
        showMainWindow()
    }

    #if DEBUG
    /// Dev only: PLING_TEST_SERVER/USER/PASSWORD (+ PLING_TEST_TOPICS, comma-separated) create a server on first run.
    private func seedFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard !hasServers, let urlText = env["PLING_TEST_SERVER"], let url = URL(string: urlText) else { return }
        let server = Server(name: url.host() ?? "Test", url: url, authKind: .basic, username: env["PLING_TEST_USER"])
        context.insert(server)
        Keychain.set(env["PLING_TEST_PASSWORD"] ?? "", for: server.secretAccount)
        let subs = (env["PLING_TEST_TOPICS"] ?? "pling-test").split(separator: ",").map { Subscription(topic: String($0), server: server) }
        subs.forEach(context.insert)
        try? context.save()
        Task { for s in subs { await connections.backfill(s) } }
    }
    #endif

    var hasServers: Bool { ((try? context.fetchCount(FetchDescriptor<Server>())) ?? 0) > 0 }

    // MARK: Incoming

    private func handleNew(_ m: StoredMessage, subscription: Subscription) {
        guard !Prefs.defaults.bool(forKey: Prefs.doNotDisturb), !subscription.isMuted,
              m.priority >= subscription.minPriority else { return }
        if m.priority >= 4, Prefs.defaults.bool(forKey: Prefs.realertEnabled) {
            m.nextAlertAt = .now.addingTimeInterval(realertInterval)
            try? context.save()
        }
        Task { await notifier.post(m, subscription: subscription, image: await notificationImage(m)) }
    }

    private var realertInterval: TimeInterval { Double(max(Prefs.defaults.integer(forKey: Prefs.realertMinutes), 1)) * 60 }

    private func fireDueAlerts() async {
        let due = ((try? context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.nextAlertAt != nil && !$0.acknowledged }))) ?? [])
            .filter { $0.nextAlertAt! <= .now }
        let max = Prefs.defaults.integer(forKey: Prefs.realertMax)
        for m in due {
            guard let sub = subscription(m.subscriptionID) else { m.nextAlertAt = nil; continue }
            m.realertCount += 1
            let keepGoing = m.priority >= 4 && m.realertCount < max && Prefs.defaults.bool(forKey: Prefs.realertEnabled)
            m.nextAlertAt = keepGoing ? .now.addingTimeInterval(realertInterval) : nil
            m.isRead = false
            await notifier.post(m, subscription: sub, image: await notificationImage(m))
        }
        if !due.isEmpty { try? context.save() }
    }

    // MARK: Message actions

    func acknowledge(_ m: StoredMessage) {
        m.acknowledged = true
        m.isRead = true
        m.nextAlertAt = nil
        notifier.remove(m.key)
        try? context.save()
    }

    func toggleRead(_ m: StoredMessage) {
        if m.isRead { m.isRead = false; try? context.save() } else { acknowledge(m) }
    }

    func delete(_ m: StoredMessage) {
        notifier.remove(m.key)
        context.delete(m)
        try? context.save()
    }

    func markAllRead(_ messages: [StoredMessage]) {
        messages.filter { !$0.isRead }.forEach(acknowledge)
    }

    enum SnoozeOption: CaseIterable, Identifiable {
        case minutes15, hour1, tomorrow
        var id: Self { self }
        var label: String {
            switch self {
            case .minutes15: "In 15 Minutes"
            case .hour1: "In 1 Hour"
            case .tomorrow: "Tomorrow Morning"
            }
        }
        var date: Date {
            switch self {
            case .minutes15: .now.addingTimeInterval(15 * 60)
            case .hour1: .now.addingTimeInterval(60 * 60)
            case .tomorrow:
                Calendar.current.date(bySettingHour: Prefs.defaults.integer(forKey: Prefs.tomorrowHour), minute: 0, second: 0,
                                      of: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)!
            }
        }
    }

    func snooze(_ m: StoredMessage, _ option: SnoozeOption) {
        m.isRead = true
        m.acknowledged = false
        m.realertCount = 0
        m.nextAlertAt = option.date
        notifier.remove(m.key)
        try? context.save()
    }

    func perform(_ action: Action, on m: StoredMessage) async throws {
        try await ActionRunner.run(action)
        if action.clear { acknowledge(m) }
    }

    func addToReminders(_ m: StoredMessage, list: EKCalendar? = nil) async throws {
        let allowed = remindersAuthorized ? true : await requestReminders()
        guard allowed else {
            throw ActionRunner.Failure(errorDescription: "Pling doesn’t have access to Reminders. Allow it in System Settings › Privacy & Security › Reminders.")
        }
        let listID = Prefs.defaults.string(forKey: Prefs.remindersListID) ?? ""
        guard let calendar = list ?? eventStore.calendar(withIdentifier: listID)
                ?? eventStore.defaultCalendarForNewReminders() ?? reminderLists.first else {
            throw ActionRunner.Failure(errorDescription: "There’s no Reminders list to add to. Create one in Reminders first.")
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = m.title.isEmpty ? (subscription(m.subscriptionID)?.title ?? m.topic) : m.title
        reminder.notes = m.body
        reminder.url = m.click.flatMap { ActionRunner.isSafe($0) ? $0 : nil }
        reminder.calendar = calendar
        try eventStore.save(reminder, commit: true)
    }

    func handleNotification(action: String, key: String) {
        guard let m = message(key) else { return }
        switch action {
        case UNNotificationDefaultActionIdentifier:
            acknowledge(m)
            if let url = m.click, ActionRunner.isSafe(url) { NSWorkspace.shared.open(url) } else { show(m) }
        case NoteAction.ack: acknowledge(m)
        case NoteAction.snooze15: snooze(m, .minutes15)
        case NoteAction.snooze60: snooze(m, .hour1)
        case NoteAction.snoozeTomorrow: snooze(m, .tomorrow)
        case NoteAction.reminders:
            Task {
                do { try await addToReminders(m); acknowledge(m) } catch { notifier.postFailure(error.localizedDescription) }
            }
        case let id where id.hasPrefix(NoteAction.ntfyPrefix):
            let actions = m.actions.filter { [.view, .http, .copy].contains($0.action) }
            guard let i = Int(id.dropFirst(NoteAction.ntfyPrefix.count)), actions.indices.contains(i) else { return }
            Task {
                do { try await perform(actions[i], on: m) } catch { notifier.postFailure(error.localizedDescription) }
            }
        default: break
        }
    }

    // MARK: Navigation

    func show(_ m: StoredMessage) {
        selection = .topic(m.subscriptionID)
        highlightedKey = m.key
        showMainWindow()
    }

    func showMainWindow() {
        openWindow?(id: "main")
        NSApp.activate()
    }

    func compose(to subscription: Subscription? = nil) {
        composeTopic = subscription
        isComposing = true
        showMainWindow()
    }

    // MARK: Attachments

    /// Downloads (and decrypts, if needed) an attachment. Cached in memory.
    func attachmentData(_ m: StoredMessage) async throws -> Data {
        guard let url = m.attachmentURL else { throw URLError(.badURL) }
        if let cached = imageCache.object(forKey: m.key as NSString) { return cached as Data }
        guard let sub = subscription(m.subscriptionID), let server = sub.server else { throw URLError(.badURL) }
        var data = try await server.client.fetch(url)
        if let sha = m.attachmentSHA256, E2E.digest(data) != sha { throw E2E.Failure.authentication }
        if m.attachmentEncrypted {
            guard let key = connections.key(for: sub) else { throw E2E.Failure.authentication }
            data = try E2E.openData(data, key: key)
        }
        imageCache.setObject(data as NSData, forKey: m.key as NSString)
        return data
    }

    private func notificationImage(_ m: StoredMessage) async -> Data? {
        guard m.attachment?.isImage == true, (m.attachmentSize ?? 0) < 10_000_000 else { return nil }
        return try? await attachmentData(m)
    }

    // MARK: Lookup

    func messages(for item: SidebarItem) -> [StoredMessage] {
        let all = (try? context.fetch(FetchDescriptor<StoredMessage>(sortBy: [SortDescriptor(\.time, order: .reverse)]))) ?? []
        return all.filter { item.includes($0) }
    }

    func message(_ key: String) -> StoredMessage? {
        try? context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.key == key })).first
    }

    func subscription(_ id: UUID) -> Subscription? {
        try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == id })).first
    }
}
