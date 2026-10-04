import AppKit
import UniformTypeIdentifiers

/// Imports from the File menu, the Settings footers, the empty state and files dropped
/// on the window. New workspaces are added without leaving the page you're on.
@MainActor
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    weak var model: AppModel?
    weak var window: NSWindow?

    private init() {}

    // MARK: Arc

    static var arcSidebarURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }

    func importFromArc() {
        guard FileManager.default.fileExists(atPath: Self.arcSidebarURL.path) else {
            report("Couldn't find Arc's data on this Mac", success: false)
            return
        }
        Task { @MainActor in
            switch await ArcImportService.shared.importFromArc(fileURL: Self.arcSidebarURL) {
            case .success(let result):
                add(result.workspaces)
                let count = result.workspacesCreated
                report("Imported \(count) \(count == 1 ? "workspace" : "workspaces") from Arc", success: true)
            case .failure(let error):
                report("Couldn't import from Arc: \(error.localizedDescription)", success: false)
            }
        }
    }

    // MARK: Stow file

    func importStowFile(at url: URL) {
        guard let model else { return }
        do {
            let data = try Data(contentsOf: url)
            var importedId: UUID?
            try preservingSelection { importedId = try model.importWorkspace(from: data) }
            let name = importedId.flatMap { model.workspaces.first(id: $0)?.name } ?? url.deletingPathExtension().lastPathComponent
            report("Imported “\(name)”", success: true)
        } catch {
            report("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)", success: false)
        }
    }

    func chooseStowFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stow") ?? .json]
        panel.allowsMultipleSelection = false
        run(panel) { [weak self] url in self?.importStowFile(at: url) }
    }

    // MARK: Shared

    /// Adds workspaces made by an importer.
    func add(_ workspaces: [ImportWorkspace]) {
        guard let model else { return }
        preservingSelection {
            for workspace in workspaces {
                // createWorkspace selects the new workspace, so nodes land in it.
                _ = model.createWorkspace(name: workspace.name, colorId: workspace.colorId)
                for node in workspace.nodes { addNode(node, parentId: nil, model: model) }
            }
        }
    }

    private func addNode(_ node: Node, parentId: UUID?, model: AppModel) {
        switch node {
        case .link(let link):
            model.addLink(urlString: link.url, title: link.title, parentId: parentId)
        case .folder(let folder):
            let folderId = model.addFolder(name: folder.name, parentId: parentId, isExpanded: false)
            for child in folder.children { addNode(child, parentId: folderId, model: model) }
        case .task(let task):
            model.addTask(title: task.title, parentId: parentId)
        case .snippet(let snippet):
            model.addSnippet(title: snippet.title, content: snippet.content, language: snippet.language, parentId: parentId)
        }
    }

    /// Runs a change that selects a workspace (create, import) without moving you off
    /// the page you're on.
    func preservingSelection(_ change: () throws -> Void) rethrows {
        guard let model else { return }
        let wasSettings = model.state.isSettingsSelected
        let previous = model.state.selectedWorkspaceId
        let lastViewed = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        defer {
            if wasSettings {
                if previous == nil { model.selectSettings() }
                UserDefaults.standard.set(lastViewed, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            } else if let previous {
                model.selectWorkspace(id: previous)
            }
        }
        try change()
    }

    func run(_ panel: NSOpenPanel, then handle: @escaping (URL) -> Void) {
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    /// Imports report through a toast-free alert-light line: VoiceOver hears it, and a
    /// failure gets an alert so it isn't missed.
    func report(_ text: String, success: Bool) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        lastReport = (text, success)
        NotificationCenter.default.post(name: .stowImportFinished, object: nil, userInfo: ["text": text, "success": success])
        guard !success else { return }
        let alert = NSAlert()
        alert.messageText = "Import didn't finish"
        alert.informativeText = text
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private(set) var lastReport: (text: String, success: Bool)?
}

extension Notification.Name {
    static let stowImportFinished = Notification.Name("StowImportFinished")
}
