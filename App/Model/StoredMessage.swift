import Foundation
import PlingCore
import SwiftData

@Model final class StoredMessage {
    /// `<server id>|<ntfy id>` — ntfy ids are only unique per server.
    @Attribute(.unique) var key: String
    var ntfyID: String
    var subscriptionID: UUID
    var time: Date
    /// Tie-breaker: ntfy timestamps have one-second resolution.
    var receivedAt = Date.now
    var topic: String
    var title: String
    var body: String
    var priority: Int
    var tags: [String]
    var click: URL?
    var actionsData: Data?
    var isMarkdown: Bool

    var attachmentName: String?
    var attachmentType: String?
    var attachmentSize: Int?
    var attachmentURL: URL?
    var attachmentExpires: Date?
    var attachmentEncrypted = false

    var isEncrypted = false
    var decryptFailed = false
    var rawBody: String?

    var isRead = false
    var acknowledged = false
    var realertCount = 0
    var nextAlertAt: Date?

    init(key: String, ntfyID: String, subscriptionID: UUID, time: Date, topic: String, title: String,
         body: String, priority: Int, tags: [String], click: URL?, actions: [Action], isMarkdown: Bool) {
        self.key = key; self.ntfyID = ntfyID; self.subscriptionID = subscriptionID; self.time = time
        self.topic = topic; self.title = title; self.body = body; self.priority = priority; self.tags = tags
        self.click = click; self.isMarkdown = isMarkdown
        self.actions = actions
    }

    var actions: [Action] {
        get { actionsData.flatMap { try? JSONDecoder().decode([Action].self, from: $0) } ?? [] }
        set { actionsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var attachment: Attachment? {
        guard let attachmentURL, let attachmentName else { return nil }
        return Attachment(name: attachmentName, type: attachmentType, size: attachmentSize,
                          expires: attachmentExpires, url: attachmentURL)
    }

    var serverID: UUID? { UUID(uuidString: String(key.prefix { $0 != "|" })) }

    /// Fill content fields from a plain ntfy message or a decrypted payload.
    func apply(_ m: NtfyMessage) {
        title = m.title ?? ""
        body = m.message ?? ""
        priority = m.priority
        tags = m.tags
        click = m.click
        actions = m.actions
        isMarkdown = m.isMarkdown
        if let a = m.attachment {
            attachmentName = a.name; attachmentType = a.type; attachmentSize = a.size
            attachmentURL = a.url; attachmentExpires = a.expires
        }
    }

    func apply(_ p: E2EPayload) {
        title = p.title ?? ""
        body = p.message ?? ""
        if let pr = p.priority { priority = pr }
        tags = p.tags
        click = p.click
        actions = p.actions
        isMarkdown = p.markdown
        if let info = p.attachment {
            attachmentName = info.name
            attachmentType = info.type
            attachmentEncrypted = true
        }
        decryptFailed = false
    }
}
