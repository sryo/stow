import Foundation

public struct AppState: Codable, Equatable {
    public var schemaVersion: Int
    public var workspaces: [Workspace]
    public var selectedWorkspaceId: UUID?
    public var isSettingsSelected: Bool

    public init(schemaVersion: Int, workspaces: [Workspace], selectedWorkspaceId: UUID?, isSettingsSelected: Bool) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.selectedWorkspaceId = selectedWorkspaceId
        self.isSettingsSelected = isSettingsSelected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
        isSettingsSelected = try container.decodeIfPresent(Bool.self, forKey: .isSettingsSelected) ?? false
    }
}

public struct Workspace: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var colorId: WorkspaceColorId
    public var items: [Node]
    public var browserProfiles: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, colorId, items, browserProfiles
    }

    public init(id: UUID, name: String, colorId: WorkspaceColorId, items: [Node], browserProfiles: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.colorId = colorId
        self.items = items
        self.browserProfiles = browserProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorId = try container.decode(WorkspaceColorId.self, forKey: .colorId)
        items = try container.decode([Node].self, forKey: .items)
        browserProfiles = try container.decodeIfPresent([String: String].self, forKey: .browserProfiles) ?? [:]
    }
}

public struct Link: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var faviconPath: String?

    public init(id: UUID, title: String, url: String, faviconPath: String?) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconPath = faviconPath
    }
}

public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var children: [Node]
    public var isExpanded: Bool

    public init(id: UUID, name: String, children: [Node], isExpanded: Bool) {
        self.id = id
        self.name = name
        self.children = children
        self.isExpanded = isExpanded
    }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var isCompleted: Bool
    public var dueDate: Date?
    public var notes: String?
    public var createdAt: Date

    public init(id: UUID, title: String, isCompleted: Bool, dueDate: Date?, notes: String?, createdAt: Date) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.notes = notes
        self.createdAt = createdAt
    }
}

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var language: String?
    public var createdAt: Date

    public init(id: UUID, title: String, content: String, language: String?, createdAt: Date) {
        self.id = id
        self.title = title
        self.content = content
        self.language = language
        self.createdAt = createdAt
    }
}

public enum Node: Codable, Identifiable, Equatable, Hashable, Sendable {
    case folder(Folder)
    case link(Link)
    case task(TaskItem)
    case snippet(Snippet)

    public enum CodingKeys: String, CodingKey {
        case type
        case folder
        case link
        case task
        case snippet
    }

    public enum NodeType: String, Codable {
        case folder
        case link
        case task
        case snippet
    }

    public var id: UUID {
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

    public var displayName: String {
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

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

public struct NodeLocation: Equatable {
    public var parentId: UUID?
    public var index: Int

    public init(parentId: UUID?, index: Int) {
        self.parentId = parentId
        self.index = index
    }
}

public enum WorkspaceMoveDirection {
    case left
    case right
}
