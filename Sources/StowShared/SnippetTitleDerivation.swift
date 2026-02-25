import Foundation

public enum SnippetTitleDerivation {
    private static let maxTitleLength = 40

    private static let commentPrefixes = ["//", "#", "--", "/*"]
    private static let importPrefixes = ["import ", "from ", "require", "use ", "using ", "#include"]

    public static func deriveTitle(from content: String, language: String?) -> String {
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip shebangs
            if trimmed.hasPrefix("#!") { continue }

            // Skip comments
            if commentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }

            // Skip imports
            if importPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }

            let truncated = truncateAtWordBoundary(trimmed, maxLength: maxTitleLength)
            if let language, !language.isEmpty {
                return "\(language): \(truncated)"
            }
            return truncated
        }

        return "Untitled Snippet"
    }

    private static func truncateAtWordBoundary(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }

        let prefix = String(text.prefix(maxLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            let distance = prefix.distance(from: prefix.startIndex, to: lastSpace)
            if distance > maxLength / 2 {
                return String(prefix[..<lastSpace]) + "..."
            }
        }
        return prefix + "..."
    }
}
