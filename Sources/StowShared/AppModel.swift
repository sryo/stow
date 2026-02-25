import Foundation
import os

public final class AppModel {
    private let store: DataStore
    public private(set) var state: AppState
    public var onChange: (() -> Void)?
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
        let fallback = Workspace(id: UUID(), name: "Inbox", colorId: .defaultColor(), items: [])
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
        state.workspaces.removeAll { $0.id == id }
        if state.selectedWorkspaceId == id {
            state.selectedWorkspaceId = state.workspaces.first?.id
            if let newId = state.selectedWorkspaceId {
                UserDefaults.standard.set(newId.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            }
        }
        persist()
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

    // MARK: - Pinned Links

    public func pinLink(id: UUID) {
        guard let node = nodeById(id), case .link(let link) = node else { return }
        updateWorkspace(id: currentWorkspace.id) { workspace in
            guard workspace.pinnedLinks.count < Workspace.maxPinnedLinks else { return }
            guard !workspace.pinnedLinks.contains(where: { $0.id == id }) else { return }
            workspace.pinnedLinks.append(link)
        }
    }

    public func unpinLink(id: UUID) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            workspace.pinnedLinks.removeAll { $0.id == id }
        }
    }

    public func pinnedLinkById(_ id: UUID) -> Link? {
        currentWorkspace.pinnedLinks.first { $0.id == id }
    }

    public func canPinMore() -> Bool {
        currentWorkspace.pinnedLinks.count < Workspace.maxPinnedLinks
    }

    public func updatePinnedLinkFaviconPath(id: UUID, path: String?) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            if let index = workspace.pinnedLinks.firstIndex(where: { $0.id == id }) {
                workspace.pinnedLinks[index].faviconPath = path
            }
        }
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

    public func deleteNode(id: UUID) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            _ = removeNode(id: id, nodes: &workspace.items)
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

        var nodesToGroup: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in nodeIds {
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
    public func insertWorkspaceFromSync(_ workspace: Workspace) {
        guard !state.workspaces.contains(where: { $0.id == workspace.id }) else { return }
        state.workspaces.append(workspace)
    }

    private func persist(notify: Bool = true) {
        store.save(state)
        if notify {
            onChange?()
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
}
