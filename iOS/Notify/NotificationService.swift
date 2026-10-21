import CryptoKit
import Foundation
import PlingCore
import UserNotifications

/// Turns a pling-relay push into the same notification the app would post:
/// decrypts end-to-end messages, adds image attachments and the message's action buttons.
/// iOS calls in on arbitrary threads; `lock` guards the one-shot handler.
nonisolated final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock { handler = contentHandler; fallback = request.content }
        let info = request.content.userInfo
        let serverID = info["s"] as? String
        let raw = (info["m"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        work = Task { @MainActor in
            let content = await Self.content(serverID: serverID, raw: raw)
            self.finish(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(nil)
    }

    private func finish(_ content: UNNotificationContent?) {
        let (handler, fallback) = lock.withLock { defer { self.handler = nil }; return (self.handler, self.fallback) }
        handler?(content ?? fallback ?? UNNotificationContent())
    }

    @MainActor private static func content(serverID: String?, raw: Data?) async -> UNNotificationContent? {
        guard let serverID, let raw, let m = try? NtfyMessage.decode(raw),
              let directory = PushDirectory.load(), let server = directory.servers[serverID],
              let topic = server.topics[m.topic] else { return nil }

        let stored = StoredMessage(key: "\(serverID)|\(m.id)", ntfyID: m.id, subscriptionID: topic.subscriptionID, time: m.time,
                                   topic: m.topic, title: "", body: "", priority: m.priority, tags: [], click: nil, actions: [], isMarkdown: false)
        stored.apply(m)
        var key: SymmetricKey?
        if let body = m.message, E2E.isEncrypted(body) {
            if let pass = Keychain.get("e2e.\(topic.subscriptionID.uuidString)") {
                let k = E2E.key(passphrase: pass, topic: m.topic)
                if let payload = try? E2E.open(body, key: k) { stored.apply(payload); key = k }
            }
            if key == nil {
                stored.title = "Encrypted message"
                stored.body = "Open Pling to read it."
            }
        }

        let content = Notifier.content(for: stored, topicName: topic.name, image: await image(stored, key: key, client: directory.client(for: serverID)))
        content.userInfo["ntfy"] = String(data: raw, encoding: .utf8)
        let category = Notifier.category(for: stored)
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        center.setNotificationCategories(existing.filter { $0.identifier != category.identifier }.union([category]))
        content.categoryIdentifier = category.identifier
        return content
    }

    @MainActor private static func image(_ m: StoredMessage, key: SymmetricKey?, client: NtfyClient?) async -> Data? {
        guard let client, let url = m.attachmentURL, m.attachment?.isImage == true, (m.attachmentSize ?? 0) < 10_000_000,
              var data = try? await client.fetch(url) else { return nil }
        if let sha = m.attachmentSHA256, E2E.digest(data) != sha { return nil }
        if m.attachmentEncrypted {
            guard let key, let opened = try? E2E.openData(data, key: key) else { return nil }
            data = opened
        }
        return data
    }
}
