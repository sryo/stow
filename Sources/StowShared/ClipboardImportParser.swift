import Foundation

/// A single item produced by parsing clipboard text. The caller turns each item
/// into a `Node` via `AppModel.addTask` / `addLink` / `addSnippet`.
public enum ParsedItem: Equatable {
    /// `- [ ]` / `- [x]` task syntax, or its `[ ]` / `[x]` variant. Caller adds
    /// the task and toggles completion if `isCompleted == true`.
    case task(title: String, isCompleted: Bool)
    /// One URL extracted from a line of text. `defaultTitle` is the host (with
    /// any `www.` prefix preserved — strip via `Link.displayDomain` at render
    /// time); the caller will replace it once `LinkTitleService` fetches a real
    /// page title.
    case link(url: URL, defaultTitle: String)
    /// Accumulated non-URL, non-task lines roll into one snippet. `title` is the
    /// first line capped at 50 chars with an ellipsis when truncated.
    case snippet(title: String, content: String)
}

public enum ClipboardImportParser {

    /// Parses clipboard text into an ordered list of items. Empty input — or
    /// input that's only whitespace — returns `[]`; callers should handle the
    /// empty case (e.g. an alert) before invoking.
    public static func parse(_ pasted: String) -> [ParsedItem] {
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var items: [ParsedItem] = []
        var snippetLines: [String] = []

        for line in pasted.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let task = parseTask(line: line) {
                items.append(task)
                continue
            }

            let urls = extractUrls(from: trimmed)
            if !urls.isEmpty {
                for url in urls {
                    items.append(.link(url: url, defaultTitle: url.host ?? url.absoluteString))
                }
                continue
            }

            snippetLines.append(line)
        }

        if !snippetLines.isEmpty {
            let content = snippetLines.joined(separator: "\n")
            let firstLine = snippetLines.first ?? "Snippet"
            let title = firstLine.count > 50 ? String(firstLine.prefix(50)) + "…" : firstLine
            items.append(.snippet(title: title, content: content))
        }

        return items
    }

    // MARK: - Tasks

    // Matches "- [ ] text", "- [x] text", "[ ] text", "[x] text" (leading spaces tolerated).
    private static let taskPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^\s*-?\s*\[([ xX]?)\]\s*(.+)"#)
    }()

    private static func parseTask(line: String) -> ParsedItem? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = taskPattern.firstMatch(in: line, range: range),
              let checkRange = Range(match.range(at: 1), in: line),
              let textRange = Range(match.range(at: 2), in: line) else { return nil }
        let title = String(line[textRange]).trimmingCharacters(in: .whitespaces)
        let isCompleted = String(line[checkRange]).lowercased() == "x"
        return .task(title: title, isCompleted: isCompleted)
    }

    // MARK: - URLs

    // http/https URLs OR bare localhost (with optional port + path). The
    // localhost branch is the Mac-side behavior; iOS previously failed to
    // recognize `localhost:3000` as a link because URL(string:) on a bare host
    // returns nil. Bringing it here makes both platforms agree.
    private static let urlPattern: NSRegularExpression = {
        let p = #"(?i)\b(?:https?://[^\s<>"',;]+|localhost(?::\d+)?(?:/[^\s<>"',;]*)?)"#
        return try! NSRegularExpression(pattern: p)
    }()

    private static func extractUrls(from text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        var urls: [URL] = []

        urlPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let stringRange = Range(matchRange, in: text) else { return }
            let candidate = stripTrailingPunctuation(from: String(text[stringRange]))
            if let url = normalizedUrl(from: candidate) {
                urls.append(url)
            }
        }

        return urls
    }

    private static func stripTrailingPunctuation(from value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, ".,;:)]}?!".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func normalizedUrl(from candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        // Bare localhost — prepend http:// so URL(string:) returns a valid URL.
        if lower.hasPrefix("localhost") {
            return URL(string: "http://\(trimmed)")
        }
        return nil
    }
}
