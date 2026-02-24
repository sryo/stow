import Foundation

struct AppState: Codable, Equatable {
    var schemaVersion: Int
    var workspaces: [Workspace]
    var selectedWorkspaceId: UUID?
    var isSettingsSelected: Bool

    init(schemaVersion: Int, workspaces: [Workspace], selectedWorkspaceId: UUID?, isSettingsSelected: Bool) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.selectedWorkspaceId = selectedWorkspaceId
        self.isSettingsSelected = isSettingsSelected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
        isSettingsSelected = try container.decodeIfPresent(Bool.self, forKey: .isSettingsSelected) ?? false
    }
}

struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var colorId: WorkspaceColorId
    var items: [Node]
}

struct Link: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var url: String
    var faviconPath: String?
}

struct Folder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var children: [Node]
    var isExpanded: Bool
}

struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isCompleted: Bool
    var dueDate: Date?
    var notes: String?
    var createdAt: Date
}

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var content: String
    var language: String?
    var createdAt: Date
}

enum Node: Codable, Identifiable, Equatable, Hashable, Sendable {
    case folder(Folder)
    case link(Link)
    case task(TaskItem)
    case snippet(Snippet)

    enum CodingKeys: String, CodingKey {
        case type
        case folder
        case link
        case task
        case snippet
    }

    enum NodeType: String, Codable {
        case folder
        case link
        case task
        case snippet
    }

    var id: UUID {
        switch self {
        case .folder(let folder):
            return folder.id
        case .link(let link):
            return link.id
        case .task(let task):
            return task.id
        case .snippet(let snippet):
            return snippet.id
        }
    }

    var displayName: String {
        switch self {
        case .folder(let folder):
            return folder.name
        case .link(let link):
            return link.title
        case .task(let task):
            return task.title
        case .snippet(let snippet):
            return snippet.title
        }
    }

    static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .folder:
            let folder = try container.decode(Folder.self, forKey: .folder)
            self = .folder(folder)
        case .link:
            let link = try container.decode(Link.self, forKey: .link)
            self = .link(link)
        case .task:
            let task = try container.decode(TaskItem.self, forKey: .task)
            self = .task(task)
        case .snippet:
            let snippet = try container.decode(Snippet.self, forKey: .snippet)
            self = .snippet(snippet)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try container.encode(NodeType.folder, forKey: .type)
            try container.encode(folder, forKey: .folder)
        case .link(let link):
            try container.encode(NodeType.link, forKey: .type)
            try container.encode(link, forKey: .link)
        case .task(let task):
            try container.encode(NodeType.task, forKey: .type)
            try container.encode(task, forKey: .task)
        case .snippet(let snippet):
            try container.encode(NodeType.snippet, forKey: .type)
            try container.encode(snippet, forKey: .snippet)
        }
    }
}

struct NodeLocation: Equatable {
    var parentId: UUID?
    var index: Int
}

enum WorkspaceMoveDirection {
    case left
    case right
}
