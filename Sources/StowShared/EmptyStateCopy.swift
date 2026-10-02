import Foundation

/// Empty-state wording shared by macOS and iOS, so both platforms say the same thing.
public struct EmptyStateCopy: Equatable, Sendable {
    public let symbolName: String
    public let title: String
    public let message: String

    /// A workspace with no active items.
    public static func emptyWorkspace(name: String, isTouch: Bool) -> EmptyStateCopy {
        EmptyStateCopy(
            symbolName: "tray",
            title: "Nothing in \(name) yet",
            message: isTouch
                ? "Share a link to Stow, or tap + to add a link, folder, task or snippet."
                : "Paste a link with ⌘V, drop one here, or use + to add a folder, task or snippet."
        )
    }

    /// A search that matched nothing.
    public static func noResults(query: String, isTouch: Bool) -> EmptyStateCopy {
        EmptyStateCopy(
            symbolName: "magnifyingglass",
            title: "No matches for “\(query)”",
            message: isTouch ? "Try a different word." : "Try a different word, or press Esc to clear the search."
        )
    }
}
