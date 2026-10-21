#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CryptoKit
import Foundation
import Network
import OSLog
import PlingCore
import SwiftData

private let log = Logger(subsystem: "com.weidhaus.pling", category: "connection")

enum ConnectionStatus: Equatable {
    case idle, connecting, connected, unauthorized, failed(String)

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unauthorized: "Sign-in failed. Check the username and password in Settings."
        case let .failed(reason): "Offline: \(reason)"
        }
    }
}

/// One long-lived JSON stream per server. Writes messages into SwiftData and hands new ones to the alerter.
@Observable final class ConnectionManager {
    private(set) var status: [UUID: ConnectionStatus] = [:]

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let onNew: (StoredMessage, Subscription) -> Void
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var keys: [UUID: SymmetricKey] = [:]
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var networkSatisfied = true

    init(context: ModelContext, onNew: @escaping (StoredMessage, Subscription) -> Void) {
        self.context = context
        self.onNew = onNew
    }

    func start() {
        prune()
        restartAll()
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        let resume = NSWorkspace.didWakeNotification, pause = NSWorkspace.willSleepNotification
        #else
        // iOS suspends background apps; pushes cover that time and the stream catches up on return.
        let center = NotificationCenter.default
        let resume = UIApplication.willEnterForegroundNotification, pause = UIApplication.didEnterBackgroundNotification
        #endif
        observers.append(center.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAll() }
        })
        observers.append(center.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied && !self.networkSatisfied { self.restartAll() }
                self.networkSatisfied = satisfied
            }
        }
        pathMonitor.start(queue: .main)
    }

    func restartAll() {
        let servers = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        for id in tasks.keys where !servers.contains(where: { $0.id == id }) { stop(id) }
        servers.forEach(connect)
    }

    func stopAll() { tasks.keys.forEach(stop) }

    func stop(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        status[id] = .idle
    }

    func connect(_ server: Server) {
        stop(server.id)
        let topics = server.subscriptions.map(\.topic)
        guard !topics.isEmpty else { return }
        let id = server.id, client = server.client
        status[id] = .connecting
        tasks[id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                do {
                    let since = self?.server(id)?.lastMessageID
                    for try await event in client.events(topics: topics, since: since) {
                        backoff = 1
                        self?.status[id] = .connected
                        if event.event == .message { self?.ingest(event, serverID: id, notify: true) }
                    }
                    self?.status[id] = .failed("connection closed")
                } catch NtfyClient.Failure.unauthorized {
                    self?.status[id] = .unauthorized
                    return
                } catch {
                    if Task.isCancelled { return }
                    log.info("stream \(id) failed: \(error.localizedDescription)")
                    self?.status[id] = .failed(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// Load the server's cache for a newly added topic without notifying.
    func backfill(_ subscription: Subscription) async {
        guard let server = subscription.server else { return }
        let id = server.id
        do {
            for m in try await server.client.poll(topics: [subscription.topic], since: "all") {
                ingest(m, serverID: id, notify: false)
            }
        } catch {
            log.info("backfill failed: \(error.localizedDescription)")
        }
    }

    func ingest(_ m: NtfyMessage, serverID: UUID, notify: Bool) {
        guard let server = server(serverID),
              let sub = server.subscriptions.first(where: { $0.topic == m.topic }) else { return }
        let key = "\(serverID.uuidString)|\(m.id)"
        if server.lastMessageID == nil || notify { server.lastMessageID = m.id }
        guard (try? context.fetchCount(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.key == key }))) == 0 else { return }
        // Each seal uses a fresh nonce, so an identical ciphertext under a new id is a replay.
        // ponytail: only catches replays within the retention window; a signed timestamp in the payload would close it fully.
        if let raw = m.message, E2E.isEncrypted(raw) {
            let subID = sub.id
            guard (try? context.fetchCount(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.subscriptionID == subID && $0.rawBody == raw }))) == 0 else { return }
        }

        let stored = StoredMessage(key: key, ntfyID: m.id, subscriptionID: sub.id, time: m.time, topic: m.topic,
                                   title: "", body: "", priority: m.priority, tags: [], click: nil, actions: [], isMarkdown: false)
        stored.apply(m)
        if E2E.isEncrypted(m.message) {
            stored.isEncrypted = true
            stored.rawBody = m.message
            decrypt(stored, subscription: sub)
        }
        if !notify { stored.isRead = true }
        context.insert(stored)
        try? context.save()
        if notify { onNew(stored, sub) }
    }

    func decrypt(_ message: StoredMessage, subscription: Subscription) {
        guard let raw = message.rawBody else { return }
        if let key = key(for: subscription), let payload = try? E2E.open(raw, key: key) {
            message.apply(payload)
        } else {
            message.decryptFailed = true
            message.title = "Encrypted message"
            message.body = subscription.hasPassphrase
                ? "This message can't be decrypted with the passphrase for this topic."
                : "Add the passphrase for this topic to read this message."
        }
    }

    /// Call after a topic's passphrase changes.
    func passphraseChanged(_ subscription: Subscription) {
        keys[subscription.id] = nil
        let id = subscription.id
        let messages = (try? context.fetch(FetchDescriptor<StoredMessage>(predicate: #Predicate { $0.subscriptionID == id && $0.isEncrypted }))) ?? []
        messages.forEach { decrypt($0, subscription: subscription) }
        try? context.save()
    }

    func key(for subscription: Subscription) -> SymmetricKey? {
        if let k = keys[subscription.id] { return k }
        guard subscription.hasPassphrase, let pass = Keychain.get(subscription.passphraseAccount) else { return nil }
        let k = E2E.key(passphrase: pass, topic: subscription.topic)
        keys[subscription.id] = k
        return k
    }

    func prune() {
        let days = Prefs.defaults.integer(forKey: Prefs.retentionDays)
        let cutoff = Date.now.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        try? context.delete(model: StoredMessage.self, where: #Predicate { $0.time < cutoff })
        try? context.save()
    }

    private func server(_ id: UUID) -> Server? {
        try? context.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })).first
    }
}
