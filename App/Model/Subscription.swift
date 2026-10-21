import Foundation
import SwiftData

@Model final class Subscription {
    var id = UUID()
    var topic: String
    var displayName: String?
    var emoji: String?
    /// `.distantFuture` means muted until unmuted.
    var mutedUntil: Date?
    /// Messages below this priority are stored but don't notify.
    var minPriority = 1
    var hasPassphrase = false
    var createdAt = Date.now
    var server: Server?

    init(topic: String, server: Server) {
        self.topic = topic
        self.server = server
    }

    var title: String { displayName?.isEmpty == false ? displayName! : topic }
    var isMuted: Bool { mutedUntil.map { $0 > .now } ?? false }
    var passphraseAccount: String { "e2e.\(id.uuidString)" }
}
