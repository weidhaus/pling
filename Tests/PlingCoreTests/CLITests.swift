import Foundation
import Testing
@testable import PlingCore

@Suite struct CLITests {
    @Test func decryptPrintsPayload() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bin = try #require(["out/Products/Debug", "debug"].map { root.appending(path: ".build/\($0)/ntfy-e2e") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }, "run swift build first")
        let body = try E2E.seal(E2EPayload(title: "Hi", message: "secret"), key: E2E.key(passphrase: "pw", topic: "t"))

        let p = Process()
        p.executableURL = bin
        p.arguments = ["decrypt", "--topic", "t", body]
        p.environment = ["PLING_E2E_PASSPHRASE": "pw"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0)
        #expect(text.contains(#""message" : "secret""#))
    }
}
