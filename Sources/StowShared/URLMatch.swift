import Foundation

/// How well an open tab matches a saved link, for bringing the tab forward instead of
/// opening the page twice. Apps keep a page's identity in its path and its view state
/// (selection, zoom, share tokens) in the query, and rewrite the query as you use them.
public enum URLMatch {
    public static let samePage = 3
    /// Same path, and the tab still has every query item the link has.
    public static let sameQuery = 2
    /// Same specific path, whatever the query. A generic path (`/watch`, `/search`) keeps
    /// the page's identity in its query, so it never matches this way.
    public static let samePath = 1

    /// The match rank, or nil when the tab shows another page.
    public static func score(saved: URL, open: URL) -> Int? {
        if URLCanonical.key(saved) == URLCanonical.key(open) { return samePage }
        guard let a = Parts(saved), let b = Parts(open), a.host == b.host, a.path == b.path else { return nil }
        if a.query == b.query { return samePage }
        if a.query.isSubset(of: b.query) { return sameQuery }
        return a.path.split(separator: "/").count >= 2 ? samePath : nil
    }

    /// The best-matching item, the first among equals.
    public static func best<T>(for saved: URL, among items: [T], url: (T) -> URL) -> T? {
        var best: (item: T, score: Int)?
        for item in items {
            guard let score = score(saved: saved, open: url(item)), score > (best?.score ?? 0) else { continue }
            best = (item, score)
            if score == samePage { break }
        }
        return best?.item
    }

    /// The saved item that best matches an open page, the first among equals.
    public static func bestSaved<T>(for page: URL, among items: [T], url: (T) -> URL) -> T? {
        var best: (item: T, score: Int)?
        for item in items {
            guard let score = score(saved: url(item), open: page), score > (best?.score ?? 0) else { continue }
            best = (item, score)
            if score == samePage { break }
        }
        return best?.item
    }

    private struct Parts {
        let host: String
        let path: String
        let query: Set<String>

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  var host = components.host?.lowercased() else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            self.host = host
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            self.path = path
            query = Set((components.queryItems ?? [])
                .filter { !URLCanonical.isTracking($0.name) }
                .map { "\($0.name)=\($0.value ?? "")" })
        }
    }
}
