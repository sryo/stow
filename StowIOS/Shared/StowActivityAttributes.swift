import ActivityKit
import Foundation
import UIKit
import StowShared

/// The Live Activity that keeps the current workspace in the Dynamic Island and on the
/// Lock Screen. Compiled into both the app (which starts and updates it) and the widget
/// extension (which draws it).
///
/// There is one activity at a time; switching workspaces updates its content rather
/// than starting a new one, so the attributes carry nothing.
struct StowActivityAttributes: ActivityAttributes {
    /// Kept small on purpose: ActivityKit caps the encoded state at 4 KB, so favicons
    /// travel by file name and the widget reads them from the App Group.
    struct ContentState: Codable, Hashable, Sendable {
        var workspaceId: UUID
        var name: String
        var monogram: String
        var colorHex: String
        var linkCount: Int
        var links: [TopLink]
        /// The workspace's SF Symbol when its icon is a symbol.
        var badgeSymbol: String? = nil
        /// Favicon file names for the workspace's 2×2 mosaic when its icon is favicons.
        /// With neither, the badge is `monogram`.
        var badgeIcons: [String]? = nil
    }

    struct TopLink: Codable, Hashable, Sendable {
        var title: String
        var url: String
        var host: String
        /// The favicon's file name in the App Group's Icons folder; nil draws the letter.
        var iconFile: String? = nil

        /// The single character drawn on the link's tile.
        var tileLetter: String {
            let source = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
            return source.first.map { String($0).uppercased() } ?? "•"
        }
    }

    /// Every color on the Lock Screen card, taken from the workspace's light palette.
    ///
    /// The Lock Screen resolves dynamic colors inconsistently (the background tint with
    /// the light palette, text with the dark one), so the card uses explicit RGB from a
    /// single palette and its ink always matches its surface.
    struct LockScreenStyle: Equatable {
        let background: StowTheme.RGB
        let name: StowTheme.RGB
        let caption: StowTheme.RGB
        let tileFill: StowTheme.RGB
        let tileInk: StowTheme.RGB
        let monogramFill: StowTheme.RGB
        let monogramInk: StowTheme.RGB

        init(colorHex: String) {
            let palette = StowTheme.colors(for: .custom(colorHex)).light
            background = palette.surface
            name = palette.inkPrimary
            caption = palette.inkSecondary
            tileFill = palette.paper
            tileInk = palette.inkPrimary
            // The disc sits on the card itself, so it takes the paper rather than the surface.
            monogramFill = palette.paper
            monogramInk = palette.inkPrimary
        }
    }

    /// The favicon `name` inside the App Group's Icons folder. Only a bare file name is
    /// accepted, so a state can't point the widget at another file in the container.
    static func iconURL(forFile name: String?, in container: URL) -> URL? {
        guard let name, !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return container.appendingPathComponent("Icons", isDirectory: true).appendingPathComponent(name)
    }

    static let maxLinks = 6
    static let urlScheme = "stow"
    static let openHost = "open"

    /// `stow://open?url=<encoded>[&workspace=<id>]`, which the app forwards to the system
    /// after selecting the workspace. A bare host gets https://, as rows open it.
    static func deepLink(for url: String, workspace: UUID? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = openHost
        let hasScheme = url.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:(?![0-9])", options: .regularExpression) != nil
        let target = hasScheme ? url : "https://\(url)"
        components.queryItems = [URLQueryItem(name: "url", value: target)]
        if let workspace { components.queryItems?.append(URLQueryItem(name: "workspace", value: workspace.uuidString)) }
        return components.url
    }

    /// The workspace a `stow://open` deep link asks to select, if any.
    static func workspace(ofDeepLink url: URL) -> UUID? {
        guard url.scheme == urlScheme, url.host == openHost,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "workspace" })?.value
        else { return nil }
        return UUID(uuidString: value)
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

/// Favicons the app saved in the App Group, scaled down to tile size: Live Activities
/// and widgets have a tight memory budget and a full-size .ico can be large.
enum FaviconImage {
    static let pixelSize: CGFloat = 64

    static func load(_ fileName: String?, container: URL = AppGroup.containerURL) -> UIImage? {
        guard let url = StowActivityAttributes.iconURL(forFile: fileName, in: container),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > pixelSize else { return image }
        return image.preparingThumbnail(of: CGSize(width: pixelSize, height: pixelSize)) ?? image
    }
}
