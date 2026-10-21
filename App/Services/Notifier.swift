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
    var onResponse: ((_ action: String, _ key: String) -> Void)?

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

    /// Posts (or re-posts, replacing the previous banner) the notification for a message.
    func post(_ m: StoredMessage, subscription: Subscription, image: Data?) async {
        let content = UNMutableNotificationContent()
        let emoji = Emoji.split(m.tags).emoji.joined()
        let topicName = [subscription.emoji, subscription.title].compactMap(\.self).joined(separator: " ")
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
        content.categoryIdentifier = category(for: m)
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
            content.sound = UNNotificationSound(named: UNNotificationSoundName("PlingUrgent.aiff"))
        }
        if let image, let file = Self.temporaryFile(image, name: m.attachmentName ?? "image"),
           let attachment = try? UNNotificationAttachment(identifier: "image", url: file) {
            content.attachments = [attachment]
        }
        do {
            try await center.add(UNNotificationRequest(identifier: m.key, content: content, trigger: nil))
        } catch {
            Logger(subsystem: "com.weidhaus.pling", category: "notify").error("post failed: \(error.localizedDescription)")
        }
    }

    func postFailure(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Action Failed"
        content.body = text
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func remove(_ key: String) {
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    private func category(for m: StoredMessage) -> String {
        let actions = m.actions.filter { [.view, .http, .copy].contains($0.action) }.prefix(3)
        let urgent = m.priority >= 4
        let id = "msg|" + actions.map(\.label).joined(separator: "|") + (urgent ? "|ack" : "")
        guard categories[id] == nil else { return id }

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
        categories[id] = UNNotificationCategory(identifier: id, actions: buttons, intentIdentifiers: [])
        center.setNotificationCategories(Set(categories.values))
        return id
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
        guard let key = response.notification.request.content.userInfo["key"] as? String else { return }
        await MainActor.run { onResponse?(action, key) }
    }
}
