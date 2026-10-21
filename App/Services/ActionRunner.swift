import AppKit
import PlingCore

/// Performs ntfy user actions (https://docs.ntfy.sh/publish/#action-buttons).
enum ActionRunner {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Schemes a message may open. Others (file:, smb:, other apps' schemes) could launch apps or mount shares.
    static func isSafe(_ url: URL) -> Bool { ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") }

    static func run(_ action: Action) async throws {
        switch action.action {
        case .view:
            guard let url = action.url, isSafe(url) else { throw Failure(errorDescription: "“\(action.label)” has no web link.") }
            NSWorkspace.shared.open(url)
        case .http:
            guard let url = action.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Failure(errorDescription: "“\(action.label)” has no web URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = action.method ?? "POST"
            action.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.httpBody = action.body.map { Data($0.utf8) }
            let (_, response) = try await URLSession.shared.data(for: request)
            if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                throw Failure(errorDescription: "“\(action.label)” returned HTTP \(code).")
            }
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action.value ?? "", forType: .string)
        case .broadcast, .unknown:
            break
        }
    }
}
