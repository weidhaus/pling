import Foundation
import Testing
@testable import PlingCore

/// Runs against a real ntfy server. Set PLING_TEST_SERVER, PLING_TEST_USER, PLING_TEST_PASSWORD
/// (e.g. `set -a; . ../.env.local; set +a; swift test`). Skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLING_TEST_SERVER"] != nil))
struct IntegrationTests {
    let client: NtfyClient = {
        let env = ProcessInfo.processInfo.environment
        return NtfyClient(baseURL: URL(string: env["PLING_TEST_SERVER"]!)!,
                          auth: .basic(user: env["PLING_TEST_USER"] ?? "", password: env["PLING_TEST_PASSWORD"] ?? ""))
    }()
    let topic = "pling-it-\(UUID().uuidString.prefix(8))"

    @Test func publishIsStreamed() async throws {
        let stream = client.events(topics: [topic], since: nil)
        let received = Task { () -> NtfyMessage? in
            for try await m in stream where m.event == .message { return m }
            return nil
        }
        try await Task.sleep(for: .seconds(1))
        var r = PublishRequest(topic: topic, message: "integration")
        r.title = "IT"; r.priority = 4; r.tags = ["test_tube"]
        let sent = try await client.publish(r)
        let got = try await received.value
        #expect(got?.id == sent.id)
        #expect(got?.priority == 4 && got?.title == "IT")
        received.cancel()
    }

    @Test func encryptedAttachmentRoundTrip() async throws {
        let key = E2E.key(passphrase: "it-pass", topic: topic)
        let file = Data((0..<5000).map { UInt8($0 % 251) })
        var r = PublishRequest(topic: topic)
        r.title = E2E.encryptedTitle
        r.message = try E2E.seal(E2EPayload(message: "with file", attachment: .init(name: "x.bin", type: nil)), key: key)
        r.attachment = .init(data: try E2E.sealData(file, key: key), filename: "attachment.bin")
        _ = try await client.publish(r)

        let polled = try #require(try await client.poll(topics: [topic], since: nil).last)
        #expect(try E2E.open(polled.message ?? "", key: key).message == "with file")
        let url = try #require(polled.attachment?.url)
        #expect(try E2E.openData(try await client.fetch(url), key: key) == file)
    }

    @Test func wrongPasswordIsUnauthorized() async {
        let bad = NtfyClient(baseURL: client.baseURL, auth: .basic(user: "pling", password: "nope"))
        await #expect(throws: NtfyClient.Failure.unauthorized) { _ = try await bad.poll(topics: [topic], since: nil) }
    }
}
