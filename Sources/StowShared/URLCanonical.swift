import Foundation

/// The one notion of "the same page" used to match saved links against browser tabs and
/// to skip saving a page twice.
public enum URLCanonical {
    /// Lowercases scheme and host, strips the fragment and an empty root path. The query
    /// stays: many single-page apps keep the page's identity in `?id=`.
    public static func key(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.string ?? url.absoluteString.lowercased()
    }

    /// `key(_:)` for a stored URL string; nil when it doesn't parse.
    public static func key(_ string: String) -> String? {
        URL(string: string).map(key)
    }
}
