import Foundation

/// ntfy renders tags that match an emoji short code as the emoji (table from github/gemoji, MIT).
public enum Emoji {
    static let table: [String: String] = {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    public static func split(_ tags: [String]) -> (emoji: [String], plain: [String]) {
        var emoji: [String] = [], plain: [String] = []
        for tag in tags {
            if let e = table[tag] { emoji.append(e) } else { plain.append(tag) }
        }
        return (emoji, plain)
    }
}
