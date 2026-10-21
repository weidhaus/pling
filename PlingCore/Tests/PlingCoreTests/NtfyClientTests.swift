import Foundation
import Testing
@testable import PlingCore

/// Serves canned responses and records requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [Data]))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            req.httpBody = data
        }
        Self.requests.append(req)
        let (status, chunks) = Self.handler?(req) ?? (200, [])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        for c in chunks { client?.urlProtocol(self, didLoad: c) }
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct NtfyClientTests {
    let client = NtfyClient(baseURL: URL(string: "https://ntfy.example.com")!,
                            auth: .basic(user: "u", password: "p"), session: StubProtocol.session())

    init() { StubProtocol.requests = []; StubProtocol.handler = nil }

    @Test func streamURL() {
        #expect(client.streamURL(topics: ["a", "b"], since: nil).absoluteString == "https://ntfy.example.com/a,b/json")
        #expect(client.streamURL(topics: ["a"], since: "xyz").absoluteString == "https://ntfy.example.com/a/json?since=xyz")
        #expect(client.streamURL(topics: ["a"], since: nil, poll: true).absoluteString == "https://ntfy.example.com/a/json?poll=1&since=all")
    }

    @Test func authHeaders() {
        #expect(NtfyAuth.basic(user: "u", password: "p").header == "Basic dTpw")
        #expect(NtfyAuth.token("tk_1").header == "Bearer tk_1")
        #expect(NtfyAuth.none.header == nil)
    }

    @Test func streamsLinesAcrossChunks() async throws {
        let chunks: [String] = [
            #"{"id":"o","time":1,"event":"open","topic":"a"}"# + "\n" + #"{"id":"1","time":1,"event":"mes"#,
            #"sage","topic":"a","message":"hi"}"# + "\n",
            #"{"id":"k","time":2,"event":"keepalive","topic":"a"}"# + "\n",
            #"{"id":"2","time":3,"event":"message","topic":"a","message":"yo"}"# + "\n",
        ]
        StubProtocol.handler = { _ in (200, chunks.map { Data($0.utf8) }) }
        var events: [NtfyMessage] = []
        for try await m in client.events(topics: ["a"], since: nil) { events.append(m) }
        #expect(events.map(\.event) == [.open, .message, .keepalive, .message])
        #expect(events.filter { $0.event == .message }.map(\.message) == ["hi", "yo"])
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Basic dTpw")
    }

    @Test func unauthorized() async {
        StubProtocol.handler = { _ in (401, [Data(#"{"code":40101}"#.utf8)]) }
        await #expect(throws: NtfyClient.Failure.unauthorized) {
            for try await _ in client.events(topics: ["a"], since: nil) {}
        }
    }

    @Test func publishJSON() async throws {
        StubProtocol.handler = { _ in (200, [Data(#"{"id":"n","time":1,"event":"message","topic":"a","message":"hi"}"#.utf8)]) }
        var r = PublishRequest(topic: "a", message: "hi")
        r.title = "T"; r.priority = 4; r.tags = ["warning"]; r.markdown = true
        r.actions = [Action(action: .view, label: "Open", url: URL(string: "https://x.y"))]
        let m = try await client.publish(r)
        #expect(m.id == "n")
        let req = try #require(StubProtocol.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://ntfy.example.com")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["topic"] as? String == "a")
        #expect(body["priority"] as? Int == 4)
        #expect(body["markdown"] as? Bool == true)
        #expect((body["actions"] as? [[String: Any]])?.first?["label"] as? String == "Open")
    }

    @Test func publishAttachmentUsesPUTHeaders() async throws {
        StubProtocol.handler = { _ in (200, [Data(#"{"id":"n","time":1,"event":"message","topic":"a"}"#.utf8)]) }
        var r = PublishRequest(topic: "a", message: "Grüße")
        r.title = "Photo"
        r.attachment = .init(data: Data([1, 2, 3]), filename: "cat.jpg")
        _ = try await client.publish(r)
        let req = try #require(StubProtocol.requests.first)
        #expect(req.httpMethod == "PUT")
        #expect(req.url?.absoluteString == "https://ntfy.example.com/a")
        #expect(req.value(forHTTPHeaderField: "Filename") == "cat.jpg")
        #expect(req.value(forHTTPHeaderField: "Title") == "Photo")
        #expect(req.value(forHTTPHeaderField: "Message") == "=?UTF-8?B?R3LDvMOfZQ==?=")
        #expect(req.httpBody == Data([1, 2, 3]))
    }

    @Test func fetchSendsCredentialsOnlyToSameOrigin() async throws {
        for (url, authed) in [("https://ntfy.example.com/file/x.png", true), ("https://ntfy.example.com:443/x.png", true),
                              ("http://ntfy.example.com/x.png", false), ("https://ntfy.example.com:8443/x.png", false),
                              ("https://other.example.com/x.png", false)] {
            StubProtocol.requests = []
            _ = try await client.fetch(URL(string: url)!)
            #expect((StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") != nil) == authed, "\(url)")
        }
    }
}
