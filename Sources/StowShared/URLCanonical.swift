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
        stripTracking(&components)
        return components.string ?? url.absoluteString.lowercased()
    }

    /// `string` without tracking parameters, otherwise exactly as given.
    public static func cleaned(_ string: String) -> String {
        guard var components = URLComponents(string: string), components.scheme != nil,
              components.queryItems?.contains(where: { isTracking($0.name) }) == true else { return string }
        stripTracking(&components)
        return components.string ?? string
    }

    public static func cleaned(_ url: URL) -> URL {
        URL(string: cleaned(url.absoluteString)) ?? url
    }

    /// Parameters that only say where a click came from, never which page it is.
    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id",
    ]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("utm_") || trackingNames.contains(lower)
    }

    private static func stripTracking(_ components: inout URLComponents) {
        guard let items = components.queryItems else { return }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return }
        components.queryItems = kept.isEmpty ? nil : kept
    }

    /// `key(_:)` for a stored URL string; nil when it doesn't parse.
    public static func key(_ string: String) -> String? {
        URL(string: string).map(key)
    }
}
