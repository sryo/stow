import Foundation

extension Array where Element == Node {
    /// The tree as the sidebar shows it: archived items are left out at every depth,
    /// including links and tasks archived inside a folder that isn't.
    public func unarchived() -> [Node] {
        compactMap { node in
            guard !node.isArchived else { return nil }
            if case .folder(var folder) = node {
                folder.children = folder.children.unarchived()
                return .folder(folder)
            }
            return node
        }
    }

    /// What the Archive section lists: every archived item, at whatever depth it was
    /// archived, in tree order. An archived folder comes whole with its children; an
    /// item archived inside a live folder is lifted out on its own.
    public func archivedLeaves() -> [Node] {
        flatMap { node -> [Node] in
            if node.isArchived { return [node] }
            if case .folder(let folder) = node { return folder.children.archivedLeaves() }
            return []
        }
    }
}
