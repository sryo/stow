import Foundation

/// The languages a snippet can be tagged with, shared by the Mac editor and the iPhone sheets.
/// The stored value is the name itself; nil means plain text.
public enum SnippetLanguage {
    public static let all = [
        "Swift", "Python", "JavaScript", "TypeScript", "Go", "Rust", "Java", "Kotlin", "C", "C++",
        "Ruby", "PHP", "HTML", "CSS", "SQL", "Shell", "Markdown", "JSON", "YAML", "XML",
    ]

    private static let aliases = ["bash": "Shell", "sh": "Shell", "zsh": "Shell"]

    /// The list's spelling of a stored language: "Bash" reads as "Shell" and case is ignored.
    /// A name the list doesn't know is kept as it is; empty means none.
    public static func normalized(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased()
        if let alias = aliases[key] { return alias }
        return all.first { $0.lowercased() == key } ?? trimmed
    }

    /// The picker's choices: the shared list, plus the snippet's own language at the end
    /// when the list doesn't have it, so opening and saving never drops it.
    public static func choices(including language: String?) -> [String] {
        guard let language = normalized(language), !all.contains(language) else { return all }
        return all + [language]
    }
}
