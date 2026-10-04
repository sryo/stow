import Foundation

/// A workspace's tasks and snippets, wherever they're filed: what the rail's counted
/// cells and the Tabline's pocket list. Archived items are left out at every depth.
public enum Pocket {
    public struct Contents: Equatable, Sendable {
        public var tasks: [TaskItem]
        public var snippets: [Snippet]

        public init(tasks: [TaskItem] = [], snippets: [Snippet] = []) {
            self.tasks = tasks
            self.snippets = snippets
        }

        public var count: Int { tasks.count + snippets.count }
        public var isEmpty: Bool { tasks.isEmpty && snippets.isEmpty }
    }

    /// Tree order, recursing into folders.
    public static func collect(_ nodes: [Node]) -> Contents {
        var contents = Contents()
        gather(nodes.unarchived(), into: &contents)
        return contents
    }

    private static func gather(_ nodes: [Node], into contents: inout Contents) {
        for node in nodes {
            switch node {
            case .task(let task): contents.tasks.append(task)
            case .snippet(let snippet): contents.snippets.append(snippet)
            case .folder(let folder): gather(folder.children, into: &contents)
            case .link: break
            }
        }
    }
}
