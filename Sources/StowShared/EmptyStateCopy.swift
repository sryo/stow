import Foundation

/// Which empty state a workspace list is in. Resolved the same way on macOS and iOS.
public enum EmptyStateKind: Equatable, Sendable {
    case none
    case emptyWorkspace
    case firstLaunch(hasArcData: Bool)
    case noMatches(query: String, total: Int)
    case archivedMatches(query: String, count: Int)
    case allArchived(count: Int)

    public var isFirstLaunch: Bool {
        if case .firstLaunch = self { return true }
        return false
    }

    public static func resolve(activeCount: Int, archivedCount: Int, query: String,
                               matchedCount: Int, archivedMatchedCount: Int,
                               isArchiveExpanded: Bool, isFirstLaunch: Bool, hasArcData: Bool) -> EmptyStateKind {
        if !query.isEmpty {
            if matchedCount > 0 { return .none }
            if archivedMatchedCount > 0 { return .archivedMatches(query: query, count: archivedMatchedCount) }
            return .noMatches(query: query, total: activeCount)
        }
        if activeCount > 0 { return .none }
        if archivedCount > 0 { return isArchiveExpanded ? .none : .allArchived(count: archivedCount) }
        return isFirstLaunch ? .firstLaunch(hasArcData: hasArcData) : .emptyWorkspace
    }
}

/// The one next step an empty state offers.
public enum EmptyStateAction: Equatable, Sendable {
    case paste
    case addBookmarksMenu
    case clearSearch
    case showArchivedMatches(count: Int)
    case showArchive(count: Int)
}

/// Empty-state wording shared by macOS and iOS, so both platforms say the same thing.
public struct EmptyStateCopy: Equatable, Sendable {
    /// Which Notch pose illustrates this state.
    public enum Scene: Equatable, Sendable { case waiting, searching, foundInArchive, napping, hello }

    public let scene: Scene
    public let title: String
    public let message: String
    public let action: EmptyStateAction?
    public let isTouch: Bool

    /// Title then message, read as one VoiceOver element.
    public var spokenLabel: String { "\(title). \(message)" }

    public var actionLabel: String? {
        switch action {
        case .paste: return "Paste"
        case .addBookmarksMenu: return "Add Bookmarks"
        case .clearSearch: return isTouch ? "Clear" : "Clear Search"
        case .showArchivedMatches: return "Show in Archive"
        case .showArchive(let k): return "Show \(k) Archived \(k == 1 ? "Item" : "Items")"
        case nil: return nil
        }
    }

    public var actionAccessibilityLabel: String? {
        switch action {
        case .paste: return "Paste from clipboard"
        case .addBookmarksMenu: return "Add bookmarks"
        case .clearSearch: return "Clear search"
        case .showArchivedMatches(let k): return "Show \(k) archived \(k == 1 ? "match" : "matches")"
        case .showArchive(let k): return "Show \(k) archived \(k == 1 ? "item" : "items")"
        case nil: return nil
        }
    }

    public static func make(_ kind: EmptyStateKind, workspaceName name: String, isTouch: Bool) -> EmptyStateCopy? {
        switch kind {
        case .none:
            return nil
        case .emptyWorkspace:
            return EmptyStateCopy(
                scene: .waiting,
                title: "Nothing in \(name) yet",
                message: isTouch
                    ? "Share a link to Stow from any app, or use Add."
                    : "Paste a link, task or snippet, or drag one in from your browser.",
                action: .paste, isTouch: isTouch)
        case .firstLaunch(let hasArc):
            return EmptyStateCopy(
                scene: .hello,
                title: "Start \(name) with a first link",
                message: isTouch
                    ? "Share a link to Stow from any app, or use Add."
                    : hasArc ? "Paste a link, drag one in, or import your Arc sidebar."
                             : "Paste a link, or drag one in from your browser.",
                action: hasArc && !isTouch ? .addBookmarksMenu : .paste, isTouch: isTouch)
        case .noMatches(let query, let total):
            return EmptyStateCopy(
                scene: .searching,
                title: "No matches for “\(middleTruncated(query))”",
                message: total == 1 ? "Clear the search to see the one item." : "Clear the search to see all \(total) items.",
                action: .clearSearch, isTouch: isTouch)
        case .archivedMatches(let query, let k):
            return EmptyStateCopy(
                scene: .foundInArchive,
                title: "“\(middleTruncated(query))” is only in the Archive",
                message: "\(k) archived \(k == 1 ? "item matches" : "items match") this search in \(name).",
                action: .showArchivedMatches(count: k), isTouch: isTouch)
        case .allArchived(let k):
            return EmptyStateCopy(
                scene: .napping,
                title: "Everything in \(name) is archived",
                message: "\(k) \(k == 1 ? "item is" : "items are") in the Archive and can be put back.",
                action: .showArchive(count: k), isTouch: isTouch)
        }
    }

    /// Shortens a long query in the middle so the title stays within two lines.
    public static func middleTruncated(_ text: String, limit: Int = 24) -> String {
        guard text.count > limit else { return text }
        let keep = limit - 1
        let head = text.prefix((keep + 1) / 2)
        let tail = text.suffix(keep / 2)
        return "\(head)…\(tail)"
    }
}
