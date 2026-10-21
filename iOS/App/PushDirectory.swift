import Foundation
import PlingCore

/// What the notification service extension needs to turn a push into a notification.
/// The app writes it to the shared app group; secrets stay in the shared Keychain group.
nonisolated struct PushDirectory: Codable {
    struct Topic: Codable {
        var subscriptionID: UUID
        var name: String
    }

    struct Server: Codable {
        var url: URL
        var authKind: AuthKind
        var username: String?
        var topics: [String: Topic]
    }

    /// Keyed by the app's server id, which the relay echoes back in each push.
    var servers: [String: Server] = [:]

    static let group = "group.com.weidhaus.pling"
    private static let key = "pushDirectory"

    static func load() -> PushDirectory? {
        UserDefaults(suiteName: group)?.data(forKey: key).flatMap { try? JSONDecoder().decode(PushDirectory.self, from: $0) }
    }

    func save() {
        UserDefaults(suiteName: Self.group)?.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    func client(for serverID: String) -> NtfyClient? {
        guard let s = servers[serverID] else { return nil }
        let secret = Keychain.get("server.\(serverID)") ?? ""
        let auth: NtfyAuth = switch s.authKind {
        case .none: .none
        case .basic: .basic(user: s.username ?? "", password: secret)
        case .token: .token(secret)
        }
        return NtfyClient(baseURL: s.url, auth: auth)
    }
}
