import OSLog
import SwiftData
import UIKit

private let log = Logger(subsystem: "com.weidhaus.pling", category: "push")

/// Registers this device's APNs token and topics with each server's pling-relay,
/// and writes the `PushDirectory` the notification service extension reads.
@Observable final class PushRegistrar {
    /// Per server: nil while syncing or without a relay, otherwise the last result.
    private(set) var status: [UUID: Result<Void, Error>] = [:]

    @ObservationIgnored var token: String? { didSet { scheduleSync() } }
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Relays this device is registered with, so removed servers get unregistered.
    @ObservationIgnored private var registered: [String: String] {
        get { Prefs.defaults.dictionary(forKey: "relayRegistrations") as? [String: String] ?? [:] }
        set { Prefs.defaults.set(newValue, forKey: "relayRegistrations") }
    }

    init(context: ModelContext) {
        self.context = context
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        }
    }

    /// Debounced: saves come in bursts. Also call after Do Not Disturb changes.
    func scheduleSync() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    private func sync() async {
        let servers = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        var directory = PushDirectory()
        for s in servers {
            directory.servers[s.id.uuidString] = .init(url: s.url, authKind: s.authKind, username: s.username, topics: Dictionary(
                s.subscriptions.map { ($0.topic, PushDirectory.Topic(subscriptionID: $0.id, name: [$0.emoji, $0.title].compactMap(\.self).joined(separator: " "))) },
                uniquingKeysWith: { a, _ in a }))
        }
        directory.save()

        guard let token else { return }
        var registrations: [String: String] = [:]
        for s in servers {
            guard let relay = s.relayURL else { status[s.id] = nil; continue }
            do {
                try await put(token: token, relay: relay, server: s)
                registrations[s.id.uuidString] = relay.absoluteString
                status[s.id] = .success(())
            } catch {
                log.error("register with relay failed: \(error.localizedDescription)")
                status[s.id] = .failure(error)
            }
        }
        // Unregister from relays of removed servers or changed relay URLs.
        for (id, relay) in registered where registrations[id] != relay {
            if let url = URL(string: relay) { try? await send(token: token, relay: url, method: "DELETE", body: nil, auth: nil) }
        }
        registered = registrations
    }

    private func put(token: String, relay: URL, server: Server) async throws {
        let dnd = Prefs.defaults.bool(forKey: Prefs.doNotDisturb)
        let topics: [[String: Any]] = server.subscriptions.map { sub in
            let muted = dnd ? Date.distantFuture : sub.mutedUntil
            return ["topic": sub.topic, "min_priority": sub.minPriority, "muted_until": Int(muted?.timeIntervalSince1970 ?? 0)]
        }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        let body = try JSONSerialization.data(withJSONObject: ["sandbox": sandbox, "server": server.id.uuidString, "topics": topics])
        try await send(token: token, relay: relay, method: "PUT", body: body, auth: server.auth.header)
    }

    private func send(token: String, relay: URL, method: String, body: Data?, auth: String?) async throws {
        var request = URLRequest(url: relay.appending(path: "v1/devices/\(token)"))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let reason = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RelayError(errorDescription: "The push relay answered \(code)\(reason.isEmpty ? "" : ": \(reason)").")
        }
    }

    struct RelayError: LocalizedError { let errorDescription: String? }
}

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    static var registrar: PushRegistrar?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.registrar?.token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        log.error("APNs registration failed: \(error.localizedDescription)")
    }
}
