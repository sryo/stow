import Foundation

public enum NodeFiltering {
    /// Archived nodes are skipped unless `includeArchived` is set (used to find matches
    /// that exist only in the Archive). Every word of the query must match a node's text
    /// (a link's title or address, a task's title or notes, a snippet's title or content),
    /// ignoring case and accents, or the initials of its title's words ("gd" for Google
    /// Docs). A folder whose name matches shows all its items.
    public static func filter(nodes: [Node], query: String, includeArchived: Bool = false) -> [Node] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return [] }
        return filter(nodes: nodes, words: words, includeArchived: includeArchived)
    }

    private static func filter(nodes: [Node], words: [String], includeArchived: Bool) -> [Node] {
        nodes.compactMap { node in
            guard includeArchived || !node.isArchived else { return nil }
            switch node {
            case .link(let link):
                return matches(words, title: link.title, text: [link.url]) ? node : nil
            case .folder(var folder):
                if matches(words, title: folder.name, text: []) {
                    folder.children = folder.children.filter { includeArchived || !$0.isArchived }
                } else {
                    folder.children = filter(nodes: folder.children, words: words, includeArchived: includeArchived)
                    if folder.children.isEmpty { return nil }
                }
                folder.isExpanded = true
                return .folder(folder)
            case .task(let task):
                return matches(words, title: task.title, text: [task.notes].compactMap { $0 }) ? node : nil
            case .snippet(let snippet):
                return matches(words, title: snippet.title, text: [snippet.content]) ? node : nil
            }
        }
    }

    private static func matches(_ words: [String], title: String, text: [String]) -> Bool {
        let haystacks = ([title] + text).map(fold)
        let initials = String(haystacks[0].split { !$0.isLetter && !$0.isNumber }.compactMap(\.first))
        return words.allSatisfy { word in
            haystacks.contains { $0.contains(word) }
                || (word.count >= 2 && word.allSatisfy(\.isLetter) && initials.hasPrefix(word))
        }
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
