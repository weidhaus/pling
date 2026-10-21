import Foundation
import PlingCore
import SwiftData

nonisolated enum AuthKind: String, CaseIterable, Identifiable, Codable {
    case none, basic, token
    var id: Self { self }
    var label: String {
        switch self {
        case .none: "None"
        case .basic: "Username & Password"
        case .token: "Access Token"
        }
    }
}

@Model final class Server {
    var id = UUID()
    var name: String
    var url: URL
    var authKind = AuthKind.none
    var username: String?
    var lastMessageID: String?
    /// iOS only: pling-relay that pushes this server's messages through APNs.
    var relayURL: URL?
    var createdAt = Date.now
    @Relationship(deleteRule: .cascade, inverse: \Subscription.server) var subscriptions: [Subscription] = []

    init(name: String, url: URL, authKind: AuthKind = .none, username: String? = nil) {
        self.name = name; self.url = url; self.authKind = authKind; self.username = username
    }

    /// Keychain account for the password or token.
    var secretAccount: String { "server.\(id.uuidString)" }

    var auth: NtfyAuth {
        let secret = Keychain.get(secretAccount) ?? ""
        switch authKind {
        case .none: return .none
        case .basic: return .basic(user: username ?? "", password: secret)
        case .token: return .token(secret)
        }
    }

    var client: NtfyClient { NtfyClient(baseURL: url, auth: auth) }

    var sortedSubscriptions: [Subscription] { subscriptions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
}
