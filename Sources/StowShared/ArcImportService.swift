import Foundation

// MARK: - Arc Data Models

/// Represents the root structure of Arc's StorableSidebar.json
public struct ArcData: Codable {
    public let sidebar: ArcSidebar
    public let version: Int

    public init(sidebar: ArcSidebar, version: Int) {
        self.sidebar = sidebar
        self.version = version
    }
}

/// Contains Arc's sidebar structure with containers
public struct ArcSidebar: Codable {
    public let containers: [ArcContainer]

    public init(containers: [ArcContainer]) {
        self.containers = containers
    }
}

/// Represents a container which can be an object or empty
public enum ArcContainer: Codable {
    case object(ArcContainerObject)
    case empty

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try to decode as an object first
        if let object = try? container.decode(ArcContainerObject.self) {
            self = .object(object)
        } else {
            // If it fails, treat it as empty
            _ = try? container.decode([String: String].self)
            self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let obj):
            try container.encode(obj)
        case .empty:
            try container.encode([String: String]())
        }
    }
}

/// Arc container object containing spaces and items
public struct ArcContainerObject: Codable {
    public let spaces: [ArcSpaceOrString]?
    public let items: [ArcItemOrString]?
    public let topAppsContainerIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case spaces
        case items
        case topAppsContainerIDs
    }

    public init(spaces: [ArcSpaceOrString]?, items: [ArcItemOrString]?, topAppsContainerIDs: [String]?) {
        self.spaces = spaces
        self.items = items
        self.topAppsContainerIDs = topAppsContainerIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode each field, but don't fail if any are missing or invalid
        self.spaces = try? container.decode([ArcSpaceOrString].self, forKey: .spaces)
        self.items = try? container.decode([ArcItemOrString].self, forKey: .items)
        self.topAppsContainerIDs = try? container.decode([String].self, forKey: .topAppsContainerIDs)
    }
}

/// Arc space can be either a SpaceModel object or a string reference
public enum ArcSpaceOrString: Codable {
    case space(ArcSpace)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let space = try? container.decode(ArcSpace.self) {
            self = .space(space)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected String or ArcSpace"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .space(let space):
            try container.encode(space)
        case .string(let string):
            try container.encode(string)
        }
    }
}

/// Represents an Arc space (workspace)
public struct ArcSpace: Codable {
    public let id: String
    public let title: String
    public let containerIDs: [String]

    public init(id: String, title: String, containerIDs: [String]) {
        self.id = id
        self.title = title
        self.containerIDs = containerIDs
    }

    // Helper to get pinned container ID
    public var pinnedContainerId: String? {
        guard let pinnedIndex = containerIDs.firstIndex(of: "pinned"),
              pinnedIndex + 1 < containerIDs.count else {
            return nil
        }
        return containerIDs[pinnedIndex + 1]
    }
}

/// Arc item can be either an Item object or a string reference
public enum ArcItemOrString: Codable {
    case item(ArcItem)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let item = try? container.decode(ArcItem.self) {
            self = .item(item)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected String or ArcItem"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .item(let item):
            try container.encode(item)
        case .string(let string):
            try container.encode(string)
        }
    }
}

/// Represents an Arc item (folder or link)
public struct ArcItem: Codable {
    public let id: String
    public let title: String?
    public let parentID: String?
    public let childrenIds: [String]?
    public let data: ArcItemData?

    public init(id: String, title: String?, parentID: String?, childrenIds: [String]?, data: ArcItemData?) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.childrenIds = childrenIds
        self.data = data
    }
}

/// Contains tab data for a link item
public struct ArcItemData: Codable {
    public let tab: ArcTabData?

    public init(tab: ArcTabData?) {
        self.tab = tab
    }
}

/// Tab information including URL and title
public struct ArcTabData: Codable {
    public let savedTitle: String
    public let savedURL: String
    public let timeLastActiveAt: Double?

    public init(savedTitle: String, savedURL: String, timeLastActiveAt: Double?) {
        self.savedTitle = savedTitle
        self.savedURL = savedURL
        self.timeLastActiveAt = timeLastActiveAt
    }
}

// MARK: - Import Result Models

/// Represents a workspace to be imported
public struct ImportWorkspace: Sendable {
    public let name: String
    public let colorId: WorkspaceColorId
    public let nodes: [Node]

    public init(name: String, colorId: WorkspaceColorId, nodes: [Node]) {
        self.name = name
        self.colorId = colorId
        self.nodes = nodes
    }
}

/// Result of an Arc import operation
public struct ArcImportResult: Sendable {
    public let workspaces: [ImportWorkspace]
    public let workspacesCreated: Int
    public let linksImported: Int
    public let foldersImported: Int

    public init(workspaces: [ImportWorkspace], workspacesCreated: Int, linksImported: Int, foldersImported: Int) {
        self.workspaces = workspaces
        self.workspacesCreated = workspacesCreated
        self.linksImported = linksImported
        self.foldersImported = foldersImported
    }
}

/// Errors that can occur during Arc import
public enum ArcImportError: Error {
    case fileNotFound
    case invalidJSON
    case noDataContainer
    case parsingFailed(String)
}

extension ArcImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Arc bookmark file not found. Please locate StorableSidebar.json in Arc's data directory."
        case .invalidJSON:
            return "Invalid Arc bookmark file format. The file may be corrupted."
        case .noDataContainer:
            return "No bookmark data found in Arc file. Make sure you have bookmarks in Arc."
        case .parsingFailed(let detail):
            return "Failed to parse Arc bookmarks: \(detail)"
        }
    }
}

// MARK: - Arc Import Service

public final class ArcImportService: Sendable {
    public static let shared = ArcImportService()

    private init() {}

    // MARK: - Public API

    /// Import bookmarks from Arc browser's StorableSidebar.json file
    /// - Parameter fileURL: URL to the Arc StorableSidebar.json file
    /// - Returns: Result containing import statistics or error
    public func importFromArc(fileURL: URL) async -> Result<ArcImportResult, ArcImportError> {
        // Yield to allow UI to update (show loading spinner)
        await Task.yield()

        // Perform the heavy work on a background task to avoid blocking the main thread
        return await Task.detached {
            do {
                // Read file data
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return .failure(.fileNotFound)
                }

                let data = try Data(contentsOf: fileURL)

                // Parse Arc data - this is CPU intensive
                let arcData = try self.parseArcData(data)

                // Convert to Stow workspaces - also CPU intensive
                let workspaces = try self.convertToWorkspaces(arcData)

                // Calculate statistics
                var totalLinks = 0
                var totalFolders = 0

                for workspace in workspaces {
                    let stats = self.countNodes(workspace.nodes)
                    totalLinks += stats.links
                    totalFolders += stats.folders
                }

                let result = ArcImportResult(
                    workspaces: workspaces,
                    workspacesCreated: workspaces.count,
                    linksImported: totalLinks,
                    foldersImported: totalFolders
                )

                return .success(result)

            } catch let error as ArcImportError {
                return .failure(error)
            } catch {
                return .failure(.parsingFailed(error.localizedDescription))
            }
        }.value
    }

    // MARK: - Private Methods

    /// Parse Arc JSON data
    private func parseArcData(_ data: Data) throws -> ArcData {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ArcData.self, from: data)
        } catch {
            throw ArcImportError.invalidJSON
        }
    }

    /// Convert Arc data to Stow workspaces
    private func convertToWorkspaces(_ arcData: ArcData) throws -> [ImportWorkspace] {
        // Find container with spaces and items
        var containerObject: ArcContainerObject?

        for container in arcData.sidebar.containers {
            if case .object(let obj) = container,
               obj.spaces != nil,
               obj.items != nil {
                containerObject = obj
                break
            }
        }

        guard let container = containerObject else {
            throw ArcImportError.noDataContainer
        }

        guard let spacesData = container.spaces,
              let itemsData = container.items else {
            throw ArcImportError.noDataContainer
        }

        // Build item lookup map
        let itemsMap = buildItemsMap(itemsData)

        // Parse spaces
        let spaces = spacesData.compactMap { spaceOrString -> ArcSpace? in
            if case .space(let space) = spaceOrString {
                return space
            }
            return nil
        }

        // Track used workspace names to handle duplicates
        var usedNames: [String: Int] = [:]

        // Convert each space to a workspace
        var workspaces: [ImportWorkspace] = []

        for (index, space) in spaces.enumerated() {
            // Get pinned container ID
            guard let pinnedContainerId = space.pinnedContainerId else {
                continue
            }

            // Build node hierarchy
            let nodes = buildNodeHierarchy(parentId: pinnedContainerId, items: itemsMap)

            // Skip empty spaces
            guard !nodes.isEmpty else {
                continue
            }

            // Handle duplicate workspace names
            var workspaceName = space.title
            if let count = usedNames[workspaceName] {
                workspaceName = "\(space.title) \(count + 1)"
                usedNames[space.title] = count + 1
            } else {
                usedNames[workspaceName] = 1
            }

            // Assign color based on index
            let colorId = assignColor(for: index)

            let workspace = ImportWorkspace(
                name: workspaceName,
                colorId: colorId,
                nodes: nodes
            )

            workspaces.append(workspace)
        }

        return workspaces
    }

    /// Build a map of item ID to item object
    private func buildItemsMap(_ items: [ArcItemOrString]) -> [String: ArcItem] {
        var map: [String: ArcItem] = [:]

        for itemOrString in items {
            if case .item(let item) = itemOrString {
                map[item.id] = item
            }
        }

        return map
    }

    /// Recursively build node hierarchy from Arc items.
    /// Uses `childrenIds` for canonical ordering when the parent item exists in the map,
    /// falling back to `parentID` filtering otherwise (e.g. root containers).
    private func buildNodeHierarchy(parentId: String, items: [String: ArcItem]) -> [Node] {
        var nodes: [Node] = []

        // If the parent is a known item with childrenIds, use that for ordering
        if let parentItem = items[parentId], let childrenIds = parentItem.childrenIds {
            for childId in childrenIds {
                if let node = convertItemToNode(childId, items: items) {
                    nodes.append(node)
                }
            }
        } else {
            // Fallback: find all items whose parentID matches
            let children = items.values.filter { $0.parentID == parentId }
            for item in children {
                if let node = convertItemToNode(item.id, items: items) {
                    nodes.append(node)
                }
            }
        }

        return nodes
    }

    /// Convert a single Arc item (by ID) into a Stow Node
    private func convertItemToNode(_ itemId: String, items: [String: ArcItem]) -> Node? {
        guard let item = items[itemId] else { return nil }

        // Check if it's a folder (has children)
        if let childrenIds = item.childrenIds, !childrenIds.isEmpty {
            let childNodes = buildNodeHierarchy(parentId: item.id, items: items)
            let folder = Folder(
                id: UUID(),
                name: item.title ?? "Untitled",
                children: childNodes,
                isExpanded: false
            )
            return .folder(folder)
        }
        // Check if it's a link
        else if let tabData = item.data?.tab {
            guard !tabData.savedURL.isEmpty,
                  URL(string: tabData.savedURL) != nil else {
                return nil
            }

            let link = Link(
                id: UUID(),
                title: tabData.savedTitle.isEmpty ? tabData.savedURL : tabData.savedTitle,
                url: tabData.savedURL,
                faviconPath: nil
            )
            return .link(link)
        }

        return nil
    }

    /// Collect all child IDs claimed by known containers to prevent duplication at root level
    private func collectClaimedChildIds(items: [String: ArcItem]) -> Set<String> {
        var claimed = Set<String>()
        for item in items.values {
            if let childrenIds = item.childrenIds {
                for childId in childrenIds {
                    claimed.insert(childId)
                }
            }
        }
        return claimed
    }

    /// Assign a color to a workspace based on its index
    private func assignColor(for index: Int) -> WorkspaceColorId {
        let colors: [WorkspaceColorId] = [
            .ember, .ruby, .coral, .tangerine, .moss, .ocean, .indigo, .graphite
        ]
        return colors[index % colors.count]
    }

    /// Count links and folders in a node array
    private func countNodes(_ nodes: [Node]) -> (links: Int, folders: Int) {
        var links = 0
        var folders = 0

        for node in nodes {
            switch node {
            case .link:
                links += 1
            case .folder(let folder):
                folders += 1
                let childStats = countNodes(folder.children)
                links += childStats.links
                folders += childStats.folders
            case .task, .snippet:
                links += 1
            }
        }

        return (links, folders)
    }
}
