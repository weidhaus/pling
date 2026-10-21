import Foundation

/// One event from an ntfy JSON stream (https://docs.ntfy.sh/subscribe/api/#json-message-format).
public struct NtfyMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Event: String, Codable, Sendable {
        case open, keepalive, message, pollRequest = "poll_request"
        case messageDelete = "message_delete", messageClear = "message_clear"
        case unknown

        public init(from decoder: Decoder) throws {
            self = Event(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var time: Date
    public var expires: Date?
    public var event: Event
    public var topic: String
    public var title: String?
    public var message: String?
    public var priority: Int
    public var tags: [String]
    public var click: URL?
    public var icon: URL?
    public var actions: [Action]
    public var attachment: Attachment?
    public var contentType: String?

    public var isMarkdown: Bool { contentType == "text/markdown" }

    public init(id: String, time: Date = .now, event: Event = .message, topic: String,
                title: String? = nil, message: String? = nil, priority: Int = 3, tags: [String] = [],
                click: URL? = nil, icon: URL? = nil, actions: [Action] = [], attachment: Attachment? = nil,
                contentType: String? = nil, expires: Date? = nil) {
        self.id = id; self.time = time; self.event = event; self.topic = topic
        self.title = title; self.message = message; self.priority = priority; self.tags = tags
        self.click = click; self.icon = icon; self.actions = actions; self.attachment = attachment
        self.contentType = contentType; self.expires = expires
    }

    enum CodingKeys: String, CodingKey {
        case id, time, expires, event, topic, title, message, priority, tags, click, icon, actions, attachment
        case contentType = "content_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        time = try c.decode(Date.self, forKey: .time)
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
        event = try c.decode(Event.self, forKey: .event)
        topic = try c.decode(String.self, forKey: .topic)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 3
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        click = try? c.decodeIfPresent(URL.self, forKey: .click)
        icon = try? c.decodeIfPresent(URL.self, forKey: .icon)
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        attachment = try? c.decodeIfPresent(Attachment.self, forKey: .attachment)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
    }

    public static func decode(_ data: Data) throws -> NtfyMessage {
        try decoder.decode(NtfyMessage.self, from: data)
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

public struct Action: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case view, http, broadcast, copy, unknown
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var action: Kind
    public var label: String
    public var url: URL?
    public var method: String?
    public var headers: [String: String]
    public var body: String?
    public var clear: Bool
    public var value: String?

    public init(id: String = UUID().uuidString, action: Kind, label: String, url: URL? = nil,
                method: String? = nil, headers: [String: String] = [:], body: String? = nil,
                clear: Bool = false, value: String? = nil) {
        self.id = id; self.action = action; self.label = label; self.url = url
        self.method = method; self.headers = headers; self.body = body; self.clear = clear; self.value = value
    }

    enum CodingKeys: String, CodingKey { case id, action, label, url, method, headers, body, clear, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        action = try c.decode(Kind.self, forKey: .action)
        label = try c.decode(String.self, forKey: .label)
        url = try? c.decodeIfPresent(URL.self, forKey: .url)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        body = try c.decodeIfPresent(String.self, forKey: .body)
        clear = try c.decodeIfPresent(Bool.self, forKey: .clear) ?? false
        value = try c.decodeIfPresent(String.self, forKey: .value)
    }
}

public struct Attachment: Codable, Sendable, Hashable {
    public var name: String
    public var type: String?
    public var size: Int?
    public var expires: Date?
    public var url: URL

    public init(name: String, type: String?, size: Int?, expires: Date?, url: URL) {
        self.name = name; self.type = type; self.size = size; self.expires = expires; self.url = url
    }

    public var isImage: Bool {
        if let type { return type.hasPrefix("image/") }
        return ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased())
    }

    public var isExpired: Bool { expires.map { $0 < .now } ?? false }
}
