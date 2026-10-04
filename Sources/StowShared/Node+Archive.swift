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

    /// Links, tasks and snippets at every depth; a folder counts its contents, not itself.
    public func leafCount() -> Int {
        reduce(0) { total, node in
            if case .folder(let folder) = node { return total + folder.children.leafCount() }
            return total + 1
        }
    }

    /// What "Open all" opens: every link the sidebar shows, at any depth. Archived links,
    /// and everything inside an archived folder, stay closed.
    public func openableLinks() -> [Link] {
        unarchived().flattenLinks()
    }

    /// The item count Stow shows for a workspace (Settings, the rail tip, the editor and
    /// search): only what isn't archived, at any depth.
    public func activeItemCount() -> Int {
        unarchived().leafCount()
    }
}

extension Folder {
    /// The folder's "Open all" set: its links that aren't archived, at any depth.
    public var openableLinks: [Link] { children.openableLinks() }
}
