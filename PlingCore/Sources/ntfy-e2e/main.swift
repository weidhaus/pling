import Darwin
import Foundation
import PlingCore
import UniformTypeIdentifiers

let usage = """
usage:
  ntfy-e2e send --server URL --topic TOPIC [--title S] [--priority 1-5] [--tags a,b]
                [--click URL] [--markdown] [--file PATH] [MESSAGE]
  ntfy-e2e decrypt --topic TOPIC BODY

environment:
  PLING_E2E_PASSPHRASE   topic passphrase (prompted if unset)
  NTFY_USER, NTFY_PASSWORD or NTFY_TOKEN   server credentials
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func passphrase() -> String {
    if let p = ProcessInfo.processInfo.environment["PLING_E2E_PASSPHRASE"], !p.isEmpty { return p }
    var buf = [CChar](repeating: 0, count: 1024)
    guard let p = readpassphrase("Passphrase: ", &buf, buf.count, 0) else { fail("no passphrase") }
    return String(cString: p)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
args.removeFirst()

var options: [String: String] = [:]
var flags: Set<String> = []
var positional: [String] = []
while let arg = args.first {
    args.removeFirst()
    if arg == "--markdown" { flags.insert(arg) }
    else if arg.hasPrefix("--") {
        guard let value = args.first else { fail("missing value for \(arg)") }
        args.removeFirst()
        options[arg] = value
    } else { positional.append(arg) }
}

guard let topic = options["--topic"] else { fail(usage) }

switch command {
case "decrypt":
    guard let body = positional.first else { fail(usage) }
    do {
        let payload = try E2E.open(body, key: E2E.key(passphrase: passphrase(), topic: topic))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
    } catch { fail("decrypt failed: \(error)") }

case "send":
    guard let server = options["--server"].flatMap(URL.init(string:)) else { fail(usage) }
    let env = ProcessInfo.processInfo.environment
    let auth: NtfyAuth = if let t = env["NTFY_TOKEN"] { .token(t) }
        else if let u = env["NTFY_USER"], let p = env["NTFY_PASSWORD"] { .basic(user: u, password: p) }
        else { .none }
    let key = E2E.key(passphrase: passphrase(), topic: topic)
    let priority = options["--priority"].flatMap(Int.init)
    var payload = E2EPayload(title: options["--title"], message: positional.joined(separator: " "),
                             tags: options["--tags"]?.split(separator: ",").map(String.init) ?? [],
                             priority: priority, click: options["--click"].flatMap(URL.init(string:)),
                             markdown: flags.contains("--markdown"))
    var request = PublishRequest(topic: topic)
    request.title = E2E.encryptedTitle
    request.priority = priority
    if let path = options["--file"] {
        let url = URL(fileURLWithPath: path)
        guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
        do {
            let sealed = try E2E.sealData(data, key: key)
            payload.attachment = E2EAttachmentInfo(name: url.lastPathComponent,
                                                   type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                                                   sha256: E2E.digest(sealed))
            request.attachment = .init(data: sealed, filename: "attachment.bin")
        } catch { fail("encrypt failed: \(error)") }
    }
    do {
        request.message = try E2E.seal(payload, key: key)
        let sent = try await NtfyClient(baseURL: server, auth: auth).publish(request)
        print(sent.id)
    } catch { fail("send failed: \(error)") }

default:
    fail(usage)
}
