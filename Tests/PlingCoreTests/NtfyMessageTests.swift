import Foundation
import Testing
@testable import PlingCore

@Suite struct NtfyMessageTests {
    @Test func decodesFullMessage() throws {
        let json = """
        {"id":"abc","time":1700000000,"expires":1700086400,"event":"message","topic":"alerts",
         "title":"Backup failed","message":"**disk** full","priority":5,"tags":["warning","skull","backup"],
         "click":"https://example.com","icon":"https://example.com/i.png","content_type":"text/markdown",
         "actions":[{"id":"a1","action":"view","label":"Open","url":"https://example.com","clear":true},
                    {"id":"a2","action":"http","label":"Retry","url":"https://api.example.com/retry","method":"PUT",
                     "headers":{"X-Token":"t"},"body":"{}"}],
         "attachment":{"name":"cat.jpg","type":"image/jpeg","size":1234,"expires":1700086400,"url":"https://example.com/file/abc.jpg"}}
        """
        let m = try NtfyMessage.decode(Data(json.utf8))
        #expect(m.id == "abc")
        #expect(m.event == .message)
        #expect(m.time == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(m.priority == 5)
        #expect(m.isMarkdown)
        #expect(m.actions.count == 2)
        #expect(m.actions[0].action == .view && m.actions[0].clear)
        #expect(m.actions[1].action == .http && m.actions[1].method == "PUT" && m.actions[1].headers["X-Token"] == "t")
        #expect(m.attachment?.isImage == true)
        #expect(m.attachment?.url.absoluteString == "https://example.com/file/abc.jpg")
    }

    @Test func defaultsAndUnknownEvent() throws {
        let m = try NtfyMessage.decode(Data(#"{"id":"x","time":1,"event":"keepalive","topic":"t"}"#.utf8))
        #expect(m.event == .keepalive)
        #expect(m.priority == 3)
        #expect(m.tags.isEmpty && m.actions.isEmpty && m.attachment == nil)
        let u = try NtfyMessage.decode(Data(#"{"id":"x","time":1,"event":"future_thing","topic":"t"}"#.utf8))
        #expect(u.event == .unknown)
        let a = try NtfyMessage.decode(Data(#"{"id":"x","time":1,"event":"message","topic":"t","actions":[{"id":"z","action":"zap","label":"Z"}]}"#.utf8))
        #expect(a.actions.first?.action == .unknown)
    }

    @Test func emojiSplit() {
        let (emoji, plain) = Emoji.split(["warning", "skull", "backup"])
        #expect(emoji == ["⚠️", "💀"])
        #expect(plain == ["backup"])
    }
}
