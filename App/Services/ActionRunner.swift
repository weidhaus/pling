import AppKit
import PlingCore

/// Performs ntfy user actions (https://docs.ntfy.sh/publish/#action-buttons).
enum ActionRunner {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func run(_ action: Action) async throws {
        switch action.action {
        case .view:
            guard let url = action.url else { throw Failure(errorDescription: "“\(action.label)” has no URL.") }
            NSWorkspace.shared.open(url)
        case .http:
            guard let url = action.url else { throw Failure(errorDescription: "“\(action.label)” has no URL.") }
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
