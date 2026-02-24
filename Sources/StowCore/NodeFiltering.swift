import Foundation

enum NodeFiltering {
    static func filter(nodes: [Node], query: String) -> [Node] {
        let lower = query.lowercased()
        return nodes.compactMap { node in
            switch node {
            case .link(let link):
                return link.title.lowercased().contains(lower) ? node : nil
            case .folder(var folder):
                let children = filter(nodes: folder.children, query: query)
                if !children.isEmpty {
                    folder.children = children
                    folder.isExpanded = true
                    return .folder(folder)
                }
                return nil
            case .task(let task):
                let titleMatch = task.title.lowercased().contains(lower)
                let notesMatch = task.notes?.lowercased().contains(lower) ?? false
                return (titleMatch || notesMatch) ? node : nil
            case .snippet(let snippet):
                let titleMatch = snippet.title.lowercased().contains(lower)
                let contentMatch = snippet.content.lowercased().contains(lower)
                return (titleMatch || contentMatch) ? node : nil
            }
        }
    }
}
