import Foundation

/// Bangs typed in the search field, run on Return: "!g term" (or "term !g") searches a
/// site, and a quick-create bang alone ("!doc") opens that app's new-document page.
public enum SearchBang {
    /// Search URLs; `%s` takes the escaped terms.
    static let searches: [String: String] = [
        "g": "https://www.google.com/search?q=%s",
        "ddg": "https://duckduckgo.com/?q=%s",
        "b": "https://www.bing.com/search?q=%s",
        "k": "https://kagi.com/search?q=%s",
        "w": "https://en.wikipedia.org/w/index.php?search=%s",
        "yt": "https://www.youtube.com/results?search_query=%s",
        "gh": "https://github.com/search?q=%s",
        "maps": "https://www.google.com/maps/search/%s",
        "a": "https://www.amazon.com/s?k=%s",
    ]

    static let creates: [String: String] = [
        "doc": "https://docs.new",
        "sheet": "https://sheets.new",
        "slides": "https://slides.new",
        "form": "https://forms.new",
        "meet": "https://meet.new",
        "cal": "https://cal.new",
        "gist": "https://gist.new",
        "repo": "https://repo.new",
        "figma": "https://figma.new",
        "notion": "https://notion.new",
        "linear": "https://linear.new",
    ]

    public static func url(for query: String) -> URL? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = words.firstIndex(where: { $0.hasPrefix("!") && $0.count > 1 }),
              index == 0 || index == words.count - 1 else { return nil }
        let bang = words[index].dropFirst().lowercased()
        var terms = words
        terms.remove(at: index)
        if terms.isEmpty {
            return creates[bang].flatMap(URL.init(string:))
        }
        guard let template = searches[bang] else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let escaped = terms.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: escaped))
    }
}
