import Foundation

extension Link {
    /// Host with any leading "www." stripped for display.
    public var displayDomain: String? {
        guard let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Node {
    /// Every link reachable from this node, including links nested inside folders
    /// at arbitrary depth. Tasks and snippets are skipped.
    public func flattenLinks() -> [Link] {
        switch self {
        case .link(let link):
            return [link]
        case .folder(let folder):
            return folder.children.flatMap { $0.flattenLinks() }
        case .task, .snippet:
            return []
        }
    }

    /// Every node id reachable from this node, including the node itself and all
    /// descendants (regardless of kind).
    public func flattenIds() -> [UUID] {
        var ids = [id]
        if case .folder(let folder) = self {
            for child in folder.children {
                ids.append(contentsOf: child.flattenIds())
            }
        }
        return ids
    }
}

extension Sequence where Element == Node {
    /// Convenience: flatten every node in the sequence to its reachable links.
    public func flattenLinks() -> [Link] {
        flatMap { $0.flattenLinks() }
    }

    /// Convenience: flatten every node in the sequence to its reachable ids.
    public func flattenIds() -> [UUID] {
        flatMap { $0.flattenIds() }
    }
}

extension Array where Element == Workspace {
    /// First workspace whose id matches, or nil.
    public func first(id: UUID) -> Workspace? {
        first { $0.id == id }
    }

    /// Index of the first workspace whose id matches, or nil.
    public func firstIndex(id: UUID) -> Int? {
        firstIndex { $0.id == id }
    }
}
