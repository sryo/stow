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
    public static let defaultName = "Bookmarks"

    public var id: UUID
    public var name: String
    public var colorId: WorkspaceColorId
    public var items: [Node]
    public var browserProfiles: [String: String]
    public var isArchiveExpanded: Bool
    public var icon: WorkspaceIcon

    enum CodingKeys: String, CodingKey {
        case id, name, colorId, items, browserProfiles, isArchiveExpanded, icon
    }

    public init(id: UUID, name: String, colorId: WorkspaceColorId, items: [Node], browserProfiles: [String: String] = [:], isArchiveExpanded: Bool = false, icon: WorkspaceIcon = .favicons) {
        self.id = id
        self.name = name
        self.colorId = colorId
        self.items = items
        self.browserProfiles = browserProfiles
        self.isArchiveExpanded = isArchiveExpanded
        self.icon = icon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorId = try container.decode(WorkspaceColorId.self, forKey: .colorId)
        items = try container.decode([Node].self, forKey: .items)
        browserProfiles = try container.decodeIfPresent([String: String].self, forKey: .browserProfiles) ?? [:]
        isArchiveExpanded = try container.decodeIfPresent(Bool.self, forKey: .isArchiveExpanded) ?? false
        icon = try container.decodeIfPresent(WorkspaceIcon.self, forKey: .icon) ?? .favicons
    }
}

public struct Link: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var faviconPath: String?
    public var isArchived: Bool

    public init(id: UUID, title: String, url: String, faviconPath: String?, isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.url = url
        self.faviconPath = faviconPath
        self.isArchived = isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        faviconPath = try container.decodeIfPresent(String.self, forKey: .faviconPath)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var children: [Node]
    public var isExpanded: Bool
    public var isArchived: Bool

    public init(id: UUID, name: String, children: [Node], isExpanded: Bool, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.children = children
        self.isExpanded = isExpanded
        self.isArchived = isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        children = try container.decode([Node].self, forKey: .children)
        isExpanded = try container.decode(Bool.self, forKey: .isExpanded)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var isCompleted: Bool
    public var dueDate: Date?
    public var notes: String?
    public var createdAt: Date
    public var isArchived: Bool

    public init(id: UUID, title: String, isCompleted: Bool, dueDate: Date?, notes: String?, createdAt: Date, isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.notes = notes
        self.createdAt = createdAt
        self.isArchived = isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var language: String?
    public var createdAt: Date
    public var isArchived: Bool

    public init(id: UUID, title: String, content: String, language: String?, createdAt: Date, isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.language = language
        self.createdAt = createdAt
        self.isArchived = isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

/// What a workspace's tile shows: its favicons (a letter when it has none), a letter,
/// or a symbol. Stored as "favicons", "letter" or "symbol:<SF Symbol name>".
public enum WorkspaceIcon: Codable, Equatable, Hashable, Sendable {
    case favicons, letter, symbol(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "letter" {
            self = .letter
        } else if value.hasPrefix("symbol:") {
            self = .symbol(String(value.dropFirst("symbol:".count)))
        } else {
            self = .favicons
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .favicons: try container.encode("favicons")
        case .letter: try container.encode("letter")
        case .symbol(let name): try container.encode("symbol:\(name)")
        }
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

    public var isArchived: Bool {
        switch self {
        case .folder(let folder): return folder.isArchived
        case .link(let link): return link.isArchived
        case .task(let task): return task.isArchived
        case .snippet(let snippet): return snippet.isArchived
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

    /// Whether the two nodes show the same thing: every field, children included at any
    /// depth. `==` compares ids only, which is what identity needs but not a view that
    /// redraws when its node changes.
    public func hasSameContent(as other: Node) -> Bool {
        switch (self, other) {
        case let (.folder(a), .folder(b)):
            var shallowA = a, shallowB = b
            shallowA.children = []
            shallowB.children = []
            return shallowA == shallowB && a.children.count == b.children.count
                && zip(a.children, b.children).allSatisfy { $0.hasSameContent(as: $1) }
        case let (.link(a), .link(b)): return a == b
        case let (.task(a), .task(b)): return a == b
        case let (.snippet(a), .snippet(b)): return a == b
        default: return false
        }
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
