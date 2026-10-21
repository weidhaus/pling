import CryptoKit
import Foundation
import Testing
@testable import PlingCore

@Suite struct E2ETests {
    static let key = E2E.key(passphrase: "correct horse", topic: "alerts")
    let payload = E2EPayload(title: "Door", message: "Front door opened", tags: ["door"], priority: 4)

    @Test func knownAnswerKey() {
        // python3 -c 'import hashlib;print(hashlib.pbkdf2_hmac("sha256",b"correct horse",b"pling-e2e-v1:alerts",600000,32).hex())'
        let hex = Self.key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "3f4eb1b83ee4637da1ef28b964e6bccd1623c37654f4421ad70dbad6a6c735d4")
    }

    @Test func roundTrip() throws {
        let body = try E2E.seal(payload, key: Self.key)
        #expect(body.hasPrefix(E2E.prefix))
        #expect(E2E.isEncrypted(body))
        #expect(!body.contains("Front door"))
        #expect(try E2E.open(body, key: Self.key) == payload)
    }

    @Test func wrongKeyAndTamperFail() throws {
        let body = try E2E.seal(payload, key: Self.key)
        let other = E2E.key(passphrase: "wrong", topic: "alerts")
        #expect(throws: E2E.Failure.authentication) { try E2E.open(body, key: other) }

        var chars = Array(body)
        let i = chars.count - 5
        chars[i] = chars[i] == "A" ? "B" : "A"
        #expect(throws: E2E.Failure.authentication) { try E2E.open(String(chars), key: Self.key) }
        #expect(throws: E2E.Failure.notEncrypted) { try E2E.open("hello", key: Self.key) }
    }

    @Test func topicChangesKey() {
        let a = E2E.key(passphrase: "p", topic: "a").withUnsafeBytes { Data($0) }
        let b = E2E.key(passphrase: "p", topic: "b").withUnsafeBytes { Data($0) }
        #expect(a != b)
    }

    @Test func tooLarge() {
        let big = E2EPayload(message: String(repeating: "x", count: 4000))
        #expect(throws: E2E.Failure.tooLarge) { try E2E.seal(big, key: Self.key) }
    }

    @Test func dataRoundTrip() throws {
        let data = Data((0..<10_000).map { UInt8($0 % 256) })
        let sealed = try E2E.sealData(data, key: Self.key)
        #expect(sealed != data)
        #expect(try E2E.openData(sealed, key: Self.key) == data)
    }
}
