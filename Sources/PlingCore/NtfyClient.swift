import Foundation

public enum NtfyAuth: Sendable, Equatable {
    case none
    case basic(user: String, password: String)
    case token(String)

    public var header: String? {
        switch self {
        case .none: nil
        case let .basic(user, password): "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        case let .token(token): "Bearer " + token
        }
    }
}

public struct PublishRequest: Sendable {
    public struct File: Sendable {
        public var data: Data
        public var filename: String
        public init(data: Data, filename: String) { self.data = data; self.filename = filename }
    }

    public var topic: String
    public var title: String?
    public var message: String?
    public var priority: Int?
    public var tags: [String] = []
    public var click: URL?
    /// ntfy delay syntax: "30m", "tomorrow, 9am", unix timestamp.
    public var delay: String?
    public var markdown = false
    public var actions: [Action] = []
    public var attachment: File?

    public init(topic: String, message: String? = nil) { self.topic = topic; self.message = message }
}

public struct NtfyClient: Sendable {
    public enum Failure: Error, Equatable { case unauthorized, http(Int) }

    public let baseURL: URL
    public let auth: NtfyAuth
    let session: URLSession

    public init(baseURL: URL, auth: NtfyAuth, session: URLSession = .shared) {
        self.baseURL = baseURL; self.auth = auth; self.session = session
    }

    public func streamURL(topics: [String], since: String?, poll: Bool = false) -> URL {
        var url = baseURL.appending(path: topics.joined(separator: ",")).appending(path: "json")
        var query: [URLQueryItem] = []
        if poll { query.append(.init(name: "poll", value: "1")) }
        if let since { query.append(.init(name: "since", value: since)) } else if poll { query.append(.init(name: "since", value: "all")) }
        if !query.isEmpty { url.append(queryItems: query) }
        return url
    }

    /// All events (open, keepalive, message, …) of a long-lived JSON stream. Ends when the server closes it.
    public func events(topics: [String], since: String?) -> AsyncThrowingStream<NtfyMessage, Error> {
        var request = authorized(URLRequest(url: streamURL(topics: topics, since: since)))
        // ntfy sends a keepalive every 45s; treat 2 missed keepalives as a dead connection.
        request.timeoutInterval = 100
        let session = session, finalRequest = request
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    try Self.check(response)
                    for try await line in bytes.lines where !line.isEmpty {
                        if let message = try? NtfyMessage.decode(Data(line.utf8)) { continuation.yield(message) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Cached messages since `since` without keeping a connection open.
    public func poll(topics: [String], since: String?) async throws -> [NtfyMessage] {
        let (data, response) = try await session.data(for: authorized(URLRequest(url: streamURL(topics: topics, since: since, poll: true))))
        try Self.check(response)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? NtfyMessage.decode(Data($0)) }
    }

    public func publish(_ r: PublishRequest) async throws -> NtfyMessage {
        var request: URLRequest
        if let file = r.attachment {
            request = URLRequest(url: baseURL.appending(path: r.topic))
            request.httpMethod = "PUT"
            request.httpBody = file.data
            request.setValue(file.filename, forHTTPHeaderField: "Filename")
            if let v = r.title { request.setValue(Self.headerValue(v), forHTTPHeaderField: "Title") }
            if let v = r.message { request.setValue(Self.headerValue(v), forHTTPHeaderField: "Message") }
            if let v = r.priority { request.setValue(String(v), forHTTPHeaderField: "Priority") }
            if !r.tags.isEmpty { request.setValue(Self.headerValue(r.tags.joined(separator: ",")), forHTTPHeaderField: "Tags") }
            if let v = r.click { request.setValue(v.absoluteString, forHTTPHeaderField: "Click") }
            if let v = r.delay { request.setValue(v, forHTTPHeaderField: "Delay") }
            if r.markdown { request.setValue("yes", forHTTPHeaderField: "Markdown") }
            if !r.actions.isEmpty, let json = try? JSONEncoder().encode(r.actions) {
                request.setValue(Self.headerValue(String(decoding: json, as: UTF8.self)), forHTTPHeaderField: "Actions")
            }
        } else {
            request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["topic": r.topic]
            body["title"] = r.title
            body["message"] = r.message
            body["priority"] = r.priority
            if !r.tags.isEmpty { body["tags"] = r.tags }
            body["click"] = r.click?.absoluteString
            body["delay"] = r.delay
            if r.markdown { body["markdown"] = true }
            if !r.actions.isEmpty {
                body["actions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.actions))
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: authorized(request))
        try Self.check(response)
        return try NtfyMessage.decode(data)
    }

    /// Downloads an attachment. Credentials are only sent to the ntfy server itself.
    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if url.host() == baseURL.host() { request = authorized(request) }
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let header = auth.header { request.setValue(header, forHTTPHeaderField: "Authorization") }
        return request
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(http.statusCode)
        }
    }

    /// HTTP headers are ASCII; ntfy accepts RFC 2047 encoded words for everything else.
    static func headerValue(_ s: String) -> String {
        s.allSatisfy { $0.isASCII && !$0.isNewline } ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}
