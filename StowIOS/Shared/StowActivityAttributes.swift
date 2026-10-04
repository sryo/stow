import ActivityKit
import Foundation
import StowShared

/// The Live Activity that keeps the current workspace in the Dynamic Island and on the
/// Lock Screen. Compiled into both the app (which starts and updates it) and the widget
/// extension (which draws it).
///
/// There is one activity at a time; switching workspaces updates its content rather
/// than starting a new one, so the attributes carry nothing.
struct StowActivityAttributes: ActivityAttributes {
    /// Kept small on purpose: ActivityKit caps the encoded state at 4 KB and images are
    /// not allowed, so tiles are drawn from the title's first letter.
    struct ContentState: Codable, Hashable, Sendable {
        var workspaceId: UUID
        var name: String
        var monogram: String
        var colorHex: String
        var linkCount: Int
        var links: [TopLink]
    }

    struct TopLink: Codable, Hashable, Sendable {
        var title: String
        var url: String
        var host: String

        /// The single character drawn on the link's tile.
        var tileLetter: String {
            let source = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
            return source.first.map { String($0).uppercased() } ?? "•"
        }
    }

    static let maxLinks = 6
    static let urlScheme = "stow"
    static let openHost = "open"

    /// `stow://open?url=<encoded>`, which the app forwards to the system.
    static func deepLink(for url: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = openHost
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        return components.url
    }

    /// The web URL a `stow://open` deep link carries, limited to http(s) so a crafted
    /// link can't launch arbitrary schemes.
    static func target(ofDeepLink url: URL) -> URL? {
        guard url.scheme == urlScheme, url.host == openHost,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value),
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return target
    }

    /// The workspace's letters, as the Mac draws them (`WorkspaceMonogram`). Pass every
    /// workspace as `among` so colliding first letters resolve the same way.
    static func monogram(for name: String, id: UUID = UUID(), among workspaces: [(id: UUID, name: String)] = []) -> String {
        WorkspaceMonogram.resolve(id, name: name, among: workspaces)
    }
}
