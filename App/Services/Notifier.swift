import Foundation
import OSLog
import PlingCore
import UniformTypeIdentifiers
import UserNotifications

/// Action identifiers shared by notification categories and `AppModel.handleNotification`.
enum NoteAction {
    static let ack = "ack"
    static let snooze15 = "snooze.15"
    static let snooze60 = "snooze.60"
    static let snoozeTomorrow = "snooze.tomorrow"
    static let reminders = "reminders"
    static let ntfyPrefix = "ntfy."
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]
    /// `raw` is the ntfy message JSON a pushed notification carries, for messages the app hasn't stored yet.
    var onResponse: ((_ action: String, _ key: String, _ raw: String?) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Returns whether notifications are allowed (prompting the first time).
    @discardableResult func requestAuthorization() async -> Bool {
        let log = Logger(subsystem: "com.weidhaus.pling", category: "notify")
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            log.notice("authorization granted=\(granted)")
            return granted
        } catch {
            log.error("authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Posts (or re-posts, replacing the previous banner) the notification for a message, now or at `date`.
    func post(_ m: StoredMessage, subscription: Subscription, image: Data?, at date: Date? = nil) async {
        let topicName = [subscription.emoji, subscription.title].compactMap(\.self).joined(separator: " ")
        let content = Self.content(for: m, topicName: topicName, image: image)
        content.categoryIdentifier = category(for: m)
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0.timeIntervalSinceNow, 1), repeats: false) }
        do {
            try await center.add(UNNotificationRequest(identifier: m.key, content: content, trigger: trigger))
        } catch {
            Logger(subsystem: "com.weidhaus.pling", category: "notify").error("post failed: \(error.localizedDescription)")
        }
    }

    /// Notification content for a message. Shared with the iOS notification service extension.
    static func content(for m: StoredMessage, topicName: String, image: Data?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let emoji = Emoji.split(m.tags).emoji.joined()
        let lead = emoji.isEmpty ? "" : emoji + " "
        if m.title.isEmpty {
            content.title = lead + topicName
        } else {
            content.title = lead + m.title
            content.subtitle = topicName
        }
        content.body = m.isMarkdown ? Self.plain(markdown: m.body) : m.body
        if content.body.isEmpty, let name = m.attachmentName { content.body = "📎 \(name)" }
        content.threadIdentifier = m.subscriptionID.uuidString
        content.userInfo = ["key": m.key]
        switch m.priority {
        case ...2:
            content.interruptionLevel = .passive
        case 3:
            content.sound = .default
        case 4:
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        default:
            content.interruptionLevel = .timeSensitive
            #if os(macOS)
            content.sound = UNNotificationSound(named: UNNotificationSoundName("PlingUrgent.aiff"))
            #else
            content.sound = .default
            #endif
        }
        if let image, let file = temporaryFile(image, name: m.attachmentName ?? "image"),
           let attachment = try? UNNotificationAttachment(identifier: "image", url: file) {
            content.attachments = [attachment]
        }
        return content
    }

    func postFailure(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Action Failed"
        content.body = text
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func remove(_ key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
        center.removePendingNotificationRequests(withIdentifiers: [key])
    }

    private func category(for m: StoredMessage) -> String {
        let category = Self.category(for: m)
        guard categories[category.identifier] == nil else { return category.identifier }
        categories[category.identifier] = category
        center.setNotificationCategories(Set(categories.values))
        return category.identifier
    }

    static func category(for m: StoredMessage) -> UNNotificationCategory {
        let actions = m.actions.filter { [.view, .http, .copy].contains($0.action) }.prefix(3)
        let urgent = m.priority >= 4
        let id = "msg|" + actions.map(\.label).joined(separator: "|") + (urgent ? "|ack" : "")
        var buttons = actions.enumerated().map { i, a in
            UNNotificationAction(identifier: NoteAction.ntfyPrefix + String(i), title: a.label, options: a.action == .view ? [.foreground] : [])
        }
        if urgent { buttons.insert(UNNotificationAction(identifier: NoteAction.ack, title: "Acknowledge"), at: 0) }
        buttons += [
            UNNotificationAction(identifier: NoteAction.snooze15, title: "Remind Me in 15 Minutes"),
            UNNotificationAction(identifier: NoteAction.snooze60, title: "Remind Me in 1 Hour"),
            UNNotificationAction(identifier: NoteAction.snoozeTomorrow, title: "Remind Me Tomorrow"),
            UNNotificationAction(identifier: NoteAction.reminders, title: "Add to Reminders"),
        ]
        return UNNotificationCategory(identifier: id, actions: buttons, intentIdentifiers: [])
    }

    static func plain(markdown: String) -> String {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? markdown
    }

    private static func temporaryFile(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: name).pathExtension
        let url = dir.appending(path: "image.\(ext.isEmpty ? "jpg" : ext)")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard let key = info["key"] as? String else { return }
        let raw = info["ntfy"] as? String
        await MainActor.run { onResponse?(action, key, raw) }
    }
}
