import CommonCrypto
import CryptoKit
import Foundation

/// The decrypted content of a Pling-encrypted ntfy message.
public struct E2EPayload: Codable, Sendable, Equatable {
    public var title: String?
    public var message: String?
    public var tags: [String]
    public var priority: Int?
    public var click: URL?
    public var actions: [Action]
    public var markdown: Bool
    public var attachment: E2EAttachmentInfo?

    public init(title: String? = nil, message: String? = nil, tags: [String] = [], priority: Int? = nil,
                click: URL? = nil, actions: [Action] = [], markdown: Bool = false,
                attachment: E2EAttachmentInfo? = nil) {
        self.title = title; self.message = message; self.tags = tags; self.priority = priority
        self.click = click; self.actions = actions; self.markdown = markdown; self.attachment = attachment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        click = try c.decodeIfPresent(URL.self, forKey: .click)
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        markdown = try c.decodeIfPresent(Bool.self, forKey: .markdown) ?? false
        attachment = try c.decodeIfPresent(E2EAttachmentInfo.self, forKey: .attachment)
    }
}

/// Real name and type of an encrypted attachment (the uploaded file is opaque `.bin`).
public struct E2EAttachmentInfo: Codable, Sendable, Equatable {
    public var name: String
    public var type: String?
    /// Hex SHA-256 of the sealed blob, binding it to this message. Absent from older senders.
    public var sha256: String?
    public init(name: String, type: String?, sha256: String? = nil) { self.name = name; self.type = type; self.sha256 = sha256 }
}

/// Pling E2E format v1. See README "Encryption" for the spec.
public enum E2E {
    public static let prefix = "pling:e2e:v1:"
    public static let encryptedTitle = "🔒 Encrypted message"
    /// ntfy turns bodies over 4096 bytes into attachments; stay well below.
    public static let maxBodyBytes = 3072
    static let iterations: UInt32 = 600_000

    public enum Failure: Error, Equatable { case notEncrypted, badEncoding, tooLarge, authentication }

    public static func key(passphrase: String, topic: String) -> SymmetricKey {
        let password = Array(passphrase.utf8)
        let salt = Array("pling-e2e-v1:\(topic)".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 iterations, &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return SymmetricKey(data: out)
    }

    public static func isEncrypted(_ body: String?) -> Bool { body?.hasPrefix(prefix) ?? false }

    public static func seal(_ payload: E2EPayload, key: SymmetricKey) throws -> String {
        let json = try JSONEncoder().encode(payload)
        let body = prefix + base64url(try sealData(json, key: key))
        guard body.utf8.count <= maxBodyBytes else { throw Failure.tooLarge }
        return body
    }

    public static func open(_ body: String, key: SymmetricKey) throws -> E2EPayload {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(prefix) else { throw Failure.notEncrypted }
        guard let data = fromBase64url(String(body.dropFirst(prefix.count))) else { throw Failure.badEncoding }
        let json = try openData(data, key: key)
        do { return try JSONDecoder().decode(E2EPayload.self, from: json) } catch { throw Failure.badEncoding }
    }

    public static func sealData(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw Failure.badEncoding }
        return combined
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func openData(_ data: Data, key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) } catch { throw Failure.authentication }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}
