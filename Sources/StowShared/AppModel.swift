import Foundation
import Combine
import os

public final class AppModel {
    private let store: DataStore
    public private(set) var state: AppState
    /// Legacy single-assignee change callback. Kept for Mac AppDelegate; iOS
    /// prefers the multicast `changes` publisher below. Both fire from the
    /// same `persist(notify: true)` path.
    public var onChange: (() -> Void)?
    private let changesSubject = PassthroughSubject<Void, Never>()
    /// Multicast change stream. Fires after every mutation that bubbles through
    /// `persist(notify: true)` — UI subscribers should respond by re-reading
    /// whatever they expose from the model. Compatible with `.sink` and
    /// `.objectWillChange.send()` patterns alike.
    public var changes: AnyPublisher<Void, Never> { changesSubject.eraseToAnyPublisher() }
    private let logger = Logger(subsystem: "com.stow.app", category: "model")

    public init(store: DataStore = DataStore()) {
        self.store = store
        self.state = store.load()

        if !state.isSettingsSelected {
            if let savedId = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId),
               let uuid = UUID(uuidString: savedId),
               state.workspaces.contains(where: { $0.id == uuid }) {
                state.selectedWorkspaceId = uuid
            }
            if state.selectedWorkspaceId == nil {
                state.selectedWorkspaceId = state.workspaces.first?.id
            }
        }
    }

    public var workspaces: [Workspace] {
        state.workspaces
    }

    public var currentWorkspace: Workspace {
        if let selected = state.selectedWorkspaceId,
           let workspace = state.workspaces.first(where: { $0.id == selected }) {
            return workspace
        }
        if let first = state.workspaces.first {
            return first
        }
        let fallback = Workspace(id: UUID(), name: Workspace.defaultName, colorId: .defaultColor(), items: [])
        state.workspaces = [fallback]
        state.selectedWorkspaceId = fallback.id
        persist()
        return fallback
    }

    public func selectWorkspace(id: UUID) {
        guard state.workspaces.contains(where: { $0.id == id }) else { return }
        state.selectedWorkspaceId = id
        state.isSettingsSelected = false
        UserDefaults.standard.set(id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
    }

    public func selectSettings() {
        state.isSettingsSelected = true
        state.selectedWorkspaceId = nil
        persist()
    }

    @discardableResult
    public func createWorkspace(name: String, colorId: WorkspaceColorId) -> UUID {
        let workspace = Workspace(id: UUID(), name: name, colorId: colorId, items: [])
        state.workspaces.append(workspace)
        state.selectedWorkspaceId = workspace.id
        UserDefaults.standard.set(workspace.id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
        return workspace.id
    }

    public func exportWorkspace(id: UUID) throws -> Data {
        guard let workspace = state.workspaces.first(where: { $0.id == id }) else {
            throw NSError(domain: "AppModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Workspace not found"])
        }
        return try WorkspaceExporter.export(workspace: workspace, schemaVersion: state.schemaVersion)
    }

    public func shareWorkspace(id: UUID) throws -> String {
        guard let workspace = state.workspaces.first(where: { $0.id == id }) else {
            throw ShareError.workspaceNotFound
        }
        return try ShareService.createShareURL(workspace: workspace, schemaVersion: state.schemaVersion)
    }

    @discardableResult
    public func importWorkspaceFromShareURL(fragment: String) throws -> UUID {
        let data = try ShareService.decodeShareData(from: fragment)
        return try importWorkspace(from: data)
    }

    @discardableResult
    public func importWorkspace(from data: Data) throws -> UUID {
        let workspace = try WorkspaceImporter.importWorkspace(from: data, iconsDirectory: store.iconsDirectory())
        // Handle duplicate names
        var name = workspace.name
        let existingNames = Set(state.workspaces.map { $0.name })
        if existingNames.contains(name) {
            var counter = 2
            while existingNames.contains("\(name) (\(counter))") {
                counter += 1
            }
            name = "\(name) (\(counter))"
        }
        var imported = workspace
        imported.name = name
        state.workspaces.append(imported)
        state.selectedWorkspaceId = imported.id
        persist()
        return imported.id
    }

    public func renameWorkspace(id: UUID, newName: String) {
        updateWorkspace(id: id) { workspace in
            workspace.name = newName
        }
    }

    public func updateWorkspaceColor(id: UUID, colorId: WorkspaceColorId) {
        updateWorkspace(id: id) { workspace in
            workspace.colorId = colorId
        }
    }

    public func updateWorkspaceBrowserProfile(id: UUID, bundleId: String, profile: String?) {
        updateWorkspace(id: id) { workspace in
            if let profile = profile {
                workspace.browserProfiles[bundleId] = profile
            } else {
                workspace.browserProfiles.removeValue(forKey: bundleId)
            }
        }
    }

    public func deleteWorkspace(id: UUID) {
        guard state.workspaces.count > 1 else { return }
        // Collect all node IDs before removing the workspace so we can sync deletions
        let nodeIds: [UUID]
        if let workspace = state.workspaces.first(where: { $0.id == id }) {
            nodeIds = workspace.items.flattenIds()
        } else {
            nodeIds = []
        }
        state.workspaces.removeAll { $0.id == id }
        if state.selectedWorkspaceId == id {
            state.selectedWorkspaceId = state.workspaces.first?.id
            if let newId = state.selectedWorkspaceId {
                UserDefaults.standard.set(newId.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            }
        }
        persist()
        Task { @MainActor in
            CloudSyncManager.shared.scheduleDeletion(for: id)
            for nodeId in nodeIds {
                CloudSyncManager.shared.scheduleDeletion(for: nodeId)
            }
        }
    }

    public func moveWorkspace(id: UUID, direction: WorkspaceMoveDirection) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }

        let newIndex: Int
        switch direction {
        case .left:
            guard currentIndex > 0 else { return }
            newIndex = currentIndex - 1
        case .right:
            guard currentIndex < state.workspaces.count - 1 else { return }
            newIndex = currentIndex + 1
        }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: newIndex)
        persist()
    }

    public func reorderWorkspace(id: UUID, toIndex: Int) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard toIndex >= 0 && toIndex < state.workspaces.count else { return }
        guard currentIndex != toIndex else { return }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: toIndex)
        persist()
    }

    @discardableResult
    public func addFolder(name: String, parentId: UUID?, isExpanded: Bool = true) -> UUID {
        let folder = Folder(id: UUID(), name: name, children: [], isExpanded: isExpanded)
        let node = Node.folder(folder)
        insertNode(node, parentId: parentId)
        return folder.id
    }

    @discardableResult
    public func addLink(urlString: String, title: String, parentId: UUID?) -> UUID {
        let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil)
        let node = Node.link(link)
        insertNode(node, parentId: parentId)
        logger.debug("Added link \(title, privacy: .public) -> \(urlString, privacy: .public)")
        return link.id
    }

    @discardableResult
    public func addTask(title: String, parentId: UUID?) -> UUID {
        let task = TaskItem(id: UUID(), title: title, isCompleted: false, dueDate: nil, notes: nil, createdAt: Date())
        let node = Node.task(task)
        insertNode(node, parentId: parentId)
        return task.id
    }

    @discardableResult
    public func addSnippet(title: String, content: String, language: String?, parentId: UUID?) -> UUID {
        let snippet = Snippet(id: UUID(), title: title, content: content, language: language, createdAt: Date())
        let node = Node.snippet(snippet)
        insertNode(node, parentId: parentId)
        return snippet.id
    }

    public func toggleTaskCompletion(id: UUID) {
        updateNode(id: id) { node in
            if case .task(var task) = node {
                task.isCompleted = !task.isCompleted
                node = .task(task)
            }
        }
    }

    public func updateTaskDueDate(id: UUID, dueDate: Date?) {
        updateNode(id: id) { node in
            if case .task(var task) = node {
                task.dueDate = dueDate
                node = .task(task)
            }
        }
    }

    public func updateTaskNotes(id: UUID, notes: String?) {
        updateNode(id: id) { node in
            if case .task(var task) = node {
                task.notes = notes
                node = .task(task)
            }
        }
    }

    public func updateSnippetContent(id: UUID, content: String) {
        updateNode(id: id) { node in
            if case .snippet(var snippet) = node {
                snippet.content = content
                node = .snippet(snippet)
            }
        }
    }

    public func updateSnippetLanguage(id: UUID, language: String?) {
        updateNode(id: id) { node in
            if case .snippet(var snippet) = node {
                snippet.language = language
                node = .snippet(snippet)
            }
        }
    }

    public func autoDeriveTitleIfNeeded(id: UUID) {
        guard let node = nodeById(id), case .snippet(let snippet) = node else { return }
        guard snippet.title == "Untitled" && !snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let derived = SnippetTitleDerivation.deriveTitle(from: snippet.content, language: snippet.language)
        renameNode(id: id, newName: derived)
    }

    public func updateLinkUrl(id: UUID, newUrl: String) {
        updateNode(id: id) { node in
            if case .link(var link) = node {
                link.url = newUrl
                link.faviconPath = nil
                node = .link(link)
            }
        }
    }

    public func renameNode(id: UUID, newName: String) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.name = newName
                node = .folder(folder)
            case .link(var link):
                link.title = newName
                node = .link(link)
            case .task(var task):
                task.title = newName
                node = .task(task)
            case .snippet(var snippet):
                snippet.title = newName
                node = .snippet(snippet)
            }
        }
    }

    public func archiveNode(id: UUID) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.isArchived = true
                node = .folder(folder)
            case .link(var link):
                link.isArchived = true
                node = .link(link)
            case .task(var task):
                task.isArchived = true
                node = .task(task)
            case .snippet(var snippet):
                snippet.isArchived = true
                node = .snippet(snippet)
            }
        }
    }

    public func unarchiveNode(id: UUID) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.isArchived = false
                node = .folder(folder)
            case .link(var link):
                link.isArchived = false
                node = .link(link)
            case .task(var task):
                task.isArchived = false
                node = .task(task)
            case .snippet(var snippet):
                snippet.isArchived = false
                node = .snippet(snippet)
            }
        }
    }

    public func permanentlyDeleteNode(id: UUID) {
        // Collect child IDs before removal so folder children are also synced as deleted
        let childIds: [UUID]
        if let node = nodeById(id), case .folder(let folder) = node {
            childIds = folder.children.flattenIds()
        } else {
            childIds = []
        }
        updateWorkspace(id: currentWorkspace.id) { workspace in
            _ = removeNode(id: id, nodes: &workspace.items)
        }
        Task { @MainActor in
            CloudSyncManager.shared.scheduleDeletion(for: id)
            for childId in childIds {
                CloudSyncManager.shared.scheduleDeletion(for: childId)
            }
        }
    }

    public func setArchiveExpanded(workspaceId: UUID, isExpanded: Bool) {
        updateWorkspace(id: workspaceId) { workspace in
            workspace.isArchiveExpanded = isExpanded
        }
    }

    public func moveNode(id: UUID, toParentId: UUID?, index: Int) {
        guard let location = findNodeLocation(id: id, nodes: currentWorkspace.items) else { return }
        if let toParentId, isDescendant(nodeId: toParentId, in: id) { return }

        updateWorkspace(id: currentWorkspace.id) { workspace in
            guard let removedNode = removeNode(id: id, nodes: &workspace.items) else { return }

            var targetIndex = max(0, index)
            if location.parentId == toParentId, location.index < targetIndex {
                targetIndex -= 1
            }

            insertNode(removedNode, parentId: toParentId, index: targetIndex, nodes: &workspace.items)
        }
    }

    public func moveNodeToWorkspace(id: UUID, workspaceId: UUID) {
        guard workspaceId != currentWorkspace.id else { return }
        var removedNode: Node?
        updateWorkspace(id: currentWorkspace.id) { workspace in
            removedNode = removeNode(id: id, nodes: &workspace.items)
        }
        guard let node = removedNode else { return }

        updateWorkspace(id: workspaceId) { workspace in
            workspace.items.append(node)
        }
    }

    public func setFolderExpanded(id: UUID, isExpanded: Bool) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.isExpanded = isExpanded
                node = .folder(folder)
            case .link, .task, .snippet:
                break
            }
        }
    }

    public func updateLinkFaviconPath(id: UUID, path: String?) {
        if let node = nodeById(id), case .link(let link) = node, link.faviconPath == path {
            return
        }
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.faviconPath = path
                node = .link(link)
            case .folder, .task, .snippet:
                break
            }
        }
    }

    public func updateLinkTitleIfDefault(id: UUID, newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let node = nodeById(id), case .link(let link) = node else { return false }
        let defaultTitle = URL(string: link.url)?.host ?? link.url
        guard link.title == defaultTitle else { return false }
        guard link.title != trimmed else { return false }

        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.title = trimmed
                node = .link(link)
            case .folder, .task, .snippet:
                break
            }
        }
        logger.debug("Updated title for \(link.url, privacy: .public) -> \(trimmed, privacy: .public)")
        return true
    }

    public func location(of nodeId: UUID) -> NodeLocation? {
        findNodeLocation(id: nodeId, nodes: currentWorkspace.items)
    }

    public func nodeById(_ id: UUID) -> Node? {
        nodeById(id, nodes: currentWorkspace.items)
    }

    public func findNode(id: UUID, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.id == id { return node }
            if case .folder(let folder) = node {
                if let found = findNode(id: id, in: folder.children) { return found }
            }
        }
        return nil
    }

    public func moveNodesToWorkspace(nodeIds: [UUID], toWorkspaceId: UUID) {
        guard toWorkspaceId != currentWorkspace.id else { return }
        guard !nodeIds.isEmpty else { return }

        var nodesToMove: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in nodeIds {
                if let removed = removeNode(id: nodeId, nodes: &workspace.items) {
                    nodesToMove.append(removed)
                }
            }
        }

        updateWorkspace(id: toWorkspaceId) { workspace in
            workspace.items.append(contentsOf: nodesToMove)
        }
    }

    @discardableResult
    public func groupNodesInNewFolder(nodeIds: [UUID], folderName: String) -> UUID? {
        guard !nodeIds.isEmpty else { return nil }

        // Drop any id whose ancestor is also in the set — otherwise removing a folder
        // detaches its descendant from the tree, and the descendant then gets appended
        // to the new folder a SECOND time (alongside its still-nested original parent).
        let nodeIdsSet = Set(nodeIds)
        let filteredIds = nodeIds.filter { id in
            for otherId in nodeIdsSet where otherId != id {
                if let other = findNode(id: otherId, in: currentWorkspace.items),
                   case .folder(let folder) = other,
                   containsNode(id, within: .folder(folder)) {
                    return false
                }
            }
            return true
        }

        var nodesToGroup: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in filteredIds {
                if let removed = removeNode(id: nodeId, nodes: &workspace.items) {
                    nodesToGroup.append(removed)
                }
            }
        }

        guard !nodesToGroup.isEmpty else { return nil }

        let folder = Folder(id: UUID(), name: folderName, children: nodesToGroup, isExpanded: true)

        updateWorkspace(id: currentWorkspace.id) { workspace in
            workspace.items.append(.folder(folder))
        }

        return folder.id
    }

    private func insertNode(_ node: Node, parentId: UUID?) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            insertNode(node, parentId: parentId, index: nil, nodes: &workspace.items)
        }
    }

    private func updateWorkspace(id: UUID, notify: Bool = true, _ mutate: (inout Workspace) -> Void) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.workspaces[index])
        persist(notify: notify)
    }

    private func updateNode(id: UUID, notify: Bool = true, _ mutate: (inout Node) -> Void) {
        updateWorkspace(id: currentWorkspace.id, notify: notify) { workspace in
            _ = updateNode(id: id, nodes: &workspace.items, mutate)
        }
    }

    // MARK: - Sync Support

    /// Appends a workspace received from a remote sync source without generating a new ID.
    /// Only inserts if a workspace with the same ID does not already exist.
    /// If the only local workspace is an empty default workspace, replace it with the incoming one.
    public func insertWorkspaceFromSync(_ workspace: Workspace) {
        guard !state.workspaces.contains(where: { $0.id == workspace.id }) else { return }

        // Deduplicate: if the only local workspace is an empty default workspace, replace it
        if state.workspaces.count == 1,
           let local = state.workspaces.first,
           local.name == Workspace.defaultName,
           local.items.isEmpty,
           local.colorId == .defaultColor() {
            let wasSelected = state.selectedWorkspaceId == local.id
            state.workspaces[0] = workspace
            if wasSelected {
                state.selectedWorkspaceId = workspace.id
            }
        } else {
            state.workspaces.append(workspace)
        }
        persist(notify: false)
    }

    /// Updates all fields of an existing workspace from a remote sync source.
    public func updateWorkspaceFromSync(_ remote: Workspace) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == remote.id }) else { return }
        state.workspaces[index].name = remote.name
        state.workspaces[index].colorId = remote.colorId
        state.workspaces[index].browserProfiles = remote.browserProfiles
        persist(notify: false)
    }

    /// Merges metadata from a remote workspace into an existing local workspace with the same name.
    /// Merges browser profiles (remote wins for conflicts).
    public func mergeWorkspaceMetadataFromSync(remote: Workspace, intoWorkspaceId localId: UUID) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == localId }) else { return }

        state.workspaces[index].colorId = remote.colorId

        // Merge browser profiles: remote wins for conflicts
        for (bundleId, profile) in remote.browserProfiles {
            state.workspaces[index].browserProfiles[bundleId] = profile
        }

        persist(notify: false)
    }

    /// Inserts or updates a node from a remote sync source into the specified workspace.
    /// If the node already exists (by ID), it is replaced in-place. Otherwise it is appended
    /// at the given parent (or top-level if parentId is nil).
    /// When `deduplicateLinks` is true (used during workspace name-merge), new link nodes
    /// are skipped if the workspace already contains a link with the same URL.
    /// Returns false if the insert failed (e.g. parent folder not yet available).
    @discardableResult
    public func upsertNodeFromSync(node: Node, workspaceId: UUID, parentId: UUID?, deduplicateLinks: Bool = false) -> Bool {
        // Malformed records that name themselves as their own parent would create an
        // unwalkable cycle. Drop silently — sync will not retry an "impossible" record.
        if parentId == node.id {
            logger.warning("Dropped sync record naming itself as parent: \(node.id, privacy: .public)")
            return true
        }
        guard let wsIndex = state.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return false }

        // Reject if the proposed parent is a descendant of the incoming folder
        // (would create a cycle in the tree).
        if let parentId, case .folder(let folder) = node {
            if containsNode(parentId, within: .folder(folder)) ||
               isDescendantInTree(parentId, of: node.id, in: state.workspaces[wsIndex].items) {
                logger.warning("Dropped sync record that would cycle: node=\(node.id, privacy: .public) parent=\(parentId, privacy: .public)")
                return true
            }
        }

        // Try to update existing node in-place
        if updateNode(id: node.id, nodes: &state.workspaces[wsIndex].items, { existing in
            // Preserve folder children when updating a folder
            if case .folder(let existingFolder) = existing, case .folder(let incomingFolder) = node {
                var merged = incomingFolder
                merged.children = existingFolder.children
                existing = .folder(merged)
            } else {
                existing = node
            }
        }) {
            persist(notify: false)
            return true
        }

        // Node doesn't exist yet — check for link URL deduplication before inserting
        if deduplicateLinks, case .link(let link) = node {
            if workspaceContainsLinkWithURL(link.url, items: state.workspaces[wsIndex].items) {
                return true // intentionally skipped
            }
        }

        insertNode(node, parentId: parentId, index: nil, nodes: &state.workspaces[wsIndex].items)

        // If parent insert failed (parent not found), fall back to top-level
        if parentId != nil {
            if findNode(id: node.id, in: state.workspaces[wsIndex].items) == nil {
                // Return false so the caller can retry after more records arrive.
                // On final retry failure, the caller should call again with parentId: nil.
                return false
            }
        }
        persist(notify: false)
        return true
    }

    /// Recursively checks whether any link node in the tree has the given URL.
    private func workspaceContainsLinkWithURL(_ url: String, items: [Node]) -> Bool {
        for node in items {
            switch node {
            case .link(let link):
                if link.url == url { return true }
            case .folder(let folder):
                if workspaceContainsLinkWithURL(url, items: folder.children) { return true }
            case .task, .snippet:
                continue
            }
        }
        return false
    }

    /// Deletes a node by ID from any workspace. Used by sync to handle remote deletions
    /// where the node may not be in the currently selected workspace.
    public func deleteNodeFromAnyWorkspace(id: UUID) {
        for index in state.workspaces.indices {
            if removeNode(id: id, nodes: &state.workspaces[index].items) != nil {
                persist(notify: false)
                return
            }
        }
    }

    /// Reorders workspaces based on sort orders received from CloudKit.
    /// Items without a server sort order keep their current position (using their
    /// array index as fallback). Server-ordered items win ties.
    public func reorderWorkspacesFromSync(sortOrders: [UUID: Int]) {
        let indexed = state.workspaces.enumerated().map { (index, ws) -> (Workspace, Int, Int) in
            if let serverOrder = sortOrders[ws.id] {
                return (ws, serverOrder, 0) // server-ordered: priority 0 (wins ties)
            } else {
                return (ws, index, 1) // local-only: current index, priority 1
            }
        }
        state.workspaces = indexed.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }.map { $0.0 }
        persist(notify: false)
    }

    /// Reorders nodes within workspaces based on sort orders received from CloudKit.
    /// Nodes without a sort order keep their current relative position.
    public func reorderNodesFromSync(sortOrders: [UUID: Int]) {
        for index in state.workspaces.indices {
            reorderNodes(nodes: &state.workspaces[index].items, sortOrders: sortOrders)
        }
        persist(notify: false)
    }

    private func reorderNodes(nodes: inout [Node], sortOrders: [UUID: Int]) {
        // Only sort if any node in this level has a sort order
        let hasSortInfo = nodes.contains { sortOrders[$0.id] != nil }
        if hasSortInfo {
            let indexed = nodes.enumerated().map { (index, node) -> (Node, Int, Int) in
                if let serverOrder = sortOrders[node.id] {
                    return (node, serverOrder, 0)
                } else {
                    return (node, index, 1)
                }
            }
            nodes = indexed.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.2 < b.2
            }.map { $0.0 }
        }
        // Recurse into folders
        for i in nodes.indices {
            if case .folder(var folder) = nodes[i] {
                reorderNodes(nodes: &folder.children, sortOrders: sortOrders)
                nodes[i] = .folder(folder)
            }
        }
    }

    /// Deletes a workspace from a remote sync source. Unlike deleteWorkspace, this
    /// has no minimum-count guard and uses notify: false to avoid re-upload loops.
    public func deleteWorkspaceFromSync(id: UUID) {
        state.workspaces.removeAll { $0.id == id }
        if state.selectedWorkspaceId == id {
            state.selectedWorkspaceId = state.workspaces.first?.id
        }
        // Ensure at least one workspace exists
        if state.workspaces.isEmpty {
            let fallback = Workspace(id: UUID(), name: Workspace.defaultName, colorId: .defaultColor(), items: [])
            state.workspaces.append(fallback)
            state.selectedWorkspaceId = fallback.id
        }
        persist(notify: false)
    }

    private func persist(notify: Bool = true) {
        // AppModel state isn't lock-protected; all mutations must originate from
        // the main thread. CloudKit completion handlers, file watchers, and
        // background timers that mutate state MUST hop to MainActor first.
        dispatchPrecondition(condition: .onQueue(.main))
        store.save(state)
        if notify {
            onChange?()
            changesSubject.send()
        }
    }

    private func insertNode(_ node: Node, parentId: UUID?, index: Int?, nodes: inout [Node]) {
        if let parentId {
            for i in nodes.indices {
                switch nodes[i] {
                case .folder(var folder):
                    if folder.id == parentId {
                        if let index {
                            let idx = max(0, min(index, folder.children.count))
                            folder.children.insert(node, at: idx)
                        } else {
                            folder.children.append(node)
                        }
                        nodes[i] = .folder(folder)
                        return
                    }
                    insertNode(node, parentId: parentId, index: index, nodes: &folder.children)
                    nodes[i] = .folder(folder)
                case .link, .task, .snippet:
                    continue
                }
            }
        } else {
            if let index {
                let idx = max(0, min(index, nodes.count))
                nodes.insert(node, at: idx)
            } else {
                nodes.append(node)
            }
        }
    }

    private func updateNode(id: UUID, nodes: inout [Node], _ mutate: (inout Node) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                var node = nodes[index]
                mutate(&node)
                nodes[index] = node
                return true
            }
            if case .folder(var folder) = nodes[index] {
                if updateNode(id: id, nodes: &folder.children, mutate) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    private func removeNode(id: UUID, nodes: inout [Node]) -> Node? {
        for index in nodes.indices {
            if nodes[index].id == id {
                return nodes.remove(at: index)
            }
            if case .folder(var folder) = nodes[index] {
                if let removed = removeNode(id: id, nodes: &folder.children) {
                    nodes[index] = .folder(folder)
                    return removed
                }
            }
        }
        return nil
    }

    private func findNodeLocation(id: UUID, nodes: [Node], parentId: UUID? = nil) -> NodeLocation? {
        for (index, node) in nodes.enumerated() {
            if node.id == id {
                return NodeLocation(parentId: parentId, index: index)
            }
            if case .folder(let folder) = node {
                if let location = findNodeLocation(id: id, nodes: folder.children, parentId: folder.id) {
                    return location
                }
            }
        }
        return nil
    }

    private func isDescendant(nodeId: UUID, in potentialAncestorId: UUID) -> Bool {
        guard let ancestor = nodeById(potentialAncestorId, nodes: currentWorkspace.items) else { return false }
        return containsNode(nodeId, within: ancestor)
    }

    private func nodeById(_ id: UUID, nodes: [Node]) -> Node? {
        for node in nodes {
            if node.id == id { return node }
            if case .folder(let folder) = node {
                if let found = nodeById(id, nodes: folder.children) { return found }
            }
        }
        return nil
    }

    private func containsNode(_ id: UUID, within node: Node) -> Bool {
        if node.id == id { return true }
        if case .folder(let folder) = node {
            return folder.children.contains(where: { containsNode(id, within: $0) })
        }
        return false
    }

    /// True when `candidate` is a descendant of the folder identified by `ancestorId`
    /// in the given tree. Used for cycle detection across the full workspace, not just
    /// the candidate's own subtree.
    private func isDescendantInTree(_ candidate: UUID, of ancestorId: UUID, in nodes: [Node]) -> Bool {
        for node in nodes {
            if node.id == ancestorId, case .folder(let folder) = node {
                return containsNode(candidate, within: .folder(folder))
            }
            if case .folder(let folder) = node {
                if isDescendantInTree(candidate, of: ancestorId, in: folder.children) {
                    return true
                }
            }
        }
        return false
    }
}
