import AppKit
import UniformTypeIdentifiers

/// Imports from the File menu, the Settings footers, the empty state and files dropped
/// on the window. New workspaces are added without leaving the page you're on.
@MainActor
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    weak var model: AppModel?
    weak var window: NSWindow?
    var backups: BackupService?

    private init() {}

    // MARK: The source picker

    struct Choice {
        let title: String
        let source: ImportSource
        /// For a Chromium profile: its folder ("Default", "Profile 1").
        let profile: String?
    }

    /// Everything importable on this Mac: Arc if it's installed, each Chromium browser's
    /// profiles, Safari, then the two file kinds.
    func availableChoices() -> [Choice] {
        var choices: [Choice] = []
        if FileManager.default.fileExists(atPath: Self.arcSidebarURL.path) {
            choices.append(Choice(title: "Arc", source: .arc, profile: nil))
        }
        for browser in BrowserManager.installedBrowsers() {
            guard let support = BrowserManager.chromiumSupportDirectory(browser.bundleId) else { continue }
            let name = OpensIn.shortName(browser.name)
            let profiles = BrowserManager.profiles(for: browser.bundleId)
            let folders = profiles.isEmpty ? [("Default", nil as String?)] : profiles.map { ($0.directoryName, Optional($0.displayName)) }
            for (folder, display) in folders
            where FileManager.default.fileExists(atPath: support.appendingPathComponent("\(folder)/Bookmarks").path) {
                let title = profiles.count > 1 ? OpensIn.label(browserName: name, profileName: display) : name
                choices.append(Choice(title: title, source: .chromium(bundleId: browser.bundleId, name: name), profile: folder))
            }
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") != nil {
            choices.append(Choice(title: "Safari", source: .safari, profile: nil))
        }
        choices.append(Choice(title: "Bookmarks HTML file…", source: .htmlFile, profile: nil))
        choices.append(Choice(title: "Stow file…", source: .stowFile, profile: nil))
        return choices
    }

    /// File ▸ Import…, the Settings footers' Import… link and the empty state.
    func showPicker() {
        let choices = availableChoices()
        let alert = NSAlert()
        alert.messageText = "Import bookmarks"
        alert.informativeText = "Each collection becomes a new workspace. You can also drop a .stow or bookmarks HTML file on Stow's window."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for choice in choices {
            popup.addItem(withTitle: choice.title)
            if case .htmlFile = choice.source { popup.menu?.insertItem(.separator(), at: popup.numberOfItems - 1) }
        }
        popup.setAccessibilityLabel("Import from")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let title = popup.titleOfSelectedItem,
                  let choice = choices.first(where: { $0.title == title }) else { return }
            // Let the alert's sheet finish closing before a panel takes its place.
            DispatchQueue.main.async { self?.run(choice) }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    func run(_ choice: Choice) {
        switch choice.source {
        case .arc: importFromArc()
        case .chromium(let bundleId, let name): importChromium(bundleId: bundleId, name: name, profile: choice.profile ?? "Default")
        case .safari: importSafari()
        case .htmlFile: chooseFile(types: [.html]) { [weak self] in self?.importHTML(at: $0) }
        case .stowFile: chooseStowFile()
        case .stowBackup: chooseFile(types: [.json]) { [weak self] in self?.importFile($0) }
        }
    }

    // MARK: Other browsers and files

    func importChromium(bundleId: String, name: String, profile: String) {
        guard let support = BrowserManager.chromiumSupportDirectory(bundleId) else { return }
        do {
            let data = try Data(contentsOf: support.appendingPathComponent("\(profile)/Bookmarks"))
            let workspaces = try BookmarkParsers.chrome(data, browserName: name)
            finish(workspaces, from: name)
        } catch {
            report("Couldn't read \(name)'s bookmarks: \(error.localizedDescription)", success: false)
        }
    }

    func importSafari() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url) else {
            report("Stow can't read Safari's bookmarks without Full Disk Access. In Safari, choose File ▸ Export ▸ Bookmarks…, then import that HTML file.", success: false)
            return
        }
        do {
            finish(try BookmarkParsers.safari(data), from: "Safari")
        } catch {
            report(error.localizedDescription, success: false)
        }
    }

    func importHTML(at url: URL) {
        guard let html = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            report("Couldn't read \(url.lastPathComponent).", success: false)
            return
        }
        finish(BookmarkParsers.netscapeHTML(html, name: url.deletingPathExtension().lastPathComponent), from: url.lastPathComponent)
    }

    /// A file chosen or dropped on the window: a .stow workspace, bookmarks HTML, or an
    /// Export All JSON (whose workspaces are added, not swapped in).
    func importFile(_ url: URL) {
        switch ImportSource.forFile(url) {
        case .stowFile: importStowFile(at: url)
        case .htmlFile: importHTML(at: url)
        case .stowBackup:
            do {
                let state = try LibraryExport.state(fromBackup: Data(contentsOf: url))
                finish(state.workspaces.map { ImportWorkspace(name: $0.name, colorId: $0.colorId, nodes: $0.items) }, from: url.lastPathComponent)
            } catch {
                report("\(url.lastPathComponent) isn't a Stow export.", success: false)
            }
        default:
            report("Stow can't import \(url.lastPathComponent).", success: false)
        }
    }

    private func finish(_ workspaces: [ImportWorkspace], from source: String) {
        guard !workspaces.isEmpty else {
            report("No bookmarks found in \(source).", success: false)
            return
        }
        add(workspaces)
        let count = workspaces.count
        report("Imported \(count) \(count == 1 ? "workspace" : "workspaces") from \(source)", success: true)
    }

    private func chooseFile(types: [UTType], then handle: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        run(panel, then: handle)
    }

    // MARK: Export All

    /// File ▸ Export All…: Stow JSON (restorable) or bookmarks HTML, picked in the panel.
    func exportAll() {
        guard let model else { return }
        let panel = NSSavePanel()
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        format.addItems(withTitles: ["Stow (JSON)", "Bookmarks (HTML)"])
        format.setAccessibilityLabel("Format")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        let label = NSTextField(labelWithString: "Format:")
        label.frame = NSRect(x: 20, y: 11, width: 60, height: 18)
        format.frame.origin = NSPoint(x: 84, y: 7)
        holder.addSubview(label)
        holder.addSubview(format)
        panel.accessoryView = holder
        panel.nameFieldStringValue = "Stow export.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let target = FormatSwitcher(panel: panel)
        format.target = target
        format.action = #selector(FormatSwitcher.changed(_:))
        let state = model.state
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            _ = target
            guard response == .OK, let url = panel.url else { return }
            do {
                if format.indexOfSelectedItem == 1 {
                    try LibraryExport.html(state).write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try LibraryExport.json(state).write(to: url, options: .atomic)
                }
                self?.lastReport = ("Exported to \(url.lastPathComponent)", true)
            } catch {
                self?.report("Couldn't export: \(error.localizedDescription)", success: false)
            }
        }
        if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }

    /// Keeps the file extension in step with the chosen format.
    private final class FormatSwitcher: NSObject {
        weak var panel: NSSavePanel?
        init(panel: NSSavePanel) { self.panel = panel }
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            guard let panel else { return }
            let html = sender.indexOfSelectedItem == 1
            panel.allowedContentTypes = [html ? .html : .json]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + (html ? ".html" : ".json")
        }
    }

    // MARK: Restore

    /// File ▸ Restore from Backup…: picks one of the daily snapshots and swaps it in. The
    /// library being replaced is kept as a snapshot too, so a restore can be undone.
    func showRestore() {
        guard let backups, let model else { return }
        let list = backups.list()
        guard !list.isEmpty else {
            report("There are no backups yet. Stow keeps one a day.", success: false)
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Restore from a backup?"
        alert.informativeText = "Your library is replaced by the snapshot you pick. What's there now is kept as a backup, so you can come back to it."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for backup in list {
            let count = (try? LibraryExport.state(fromBackup: Data(contentsOf: backup.url)))?.workspaces.count
            popup.addItem(withTitle: formatter.string(from: backup.date) + (count.map { " · \($0) \($0 == 1 ? "workspace" : "workspaces")" } ?? ""))
        }
        popup.setAccessibilityLabel("Backup")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let backup = list[popup.indexOfSelectedItem]
            do {
                let state = try LibraryExport.state(fromBackup: Data(contentsOf: backup.url))
                try backups.restore(backup)
                model.replaceAll(with: state)
                CloudSyncManager.shared.scheduleLocalChanges()
                self?.report("Restored the backup from \(formatter.string(from: backup.date))", success: true)
            } catch {
                self?.report("Couldn't restore: \(error.localizedDescription)", success: false)
            }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

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

    private(set) var lastReport: (text: String, success: Bool)? {
        didSet {
            #if DEBUG
            // Live tests read the outcome from the log.
            if let lastReport { NSLog("StowImport: \(lastReport.success ? "ok" : "failed") — \(lastReport.text)") }
            #endif
        }
    }
}

extension Notification.Name {
    static let stowImportFinished = Notification.Name("StowImportFinished")
}

/// The main window's root view: dropping a .stow, bookmarks HTML or Export All JSON file
/// anywhere on Stow imports it.
final class FileDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func importableFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ImportSource.forFile($0) != nil }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        importableFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = importableFiles(sender)
        guard !files.isEmpty else { return false }
        MainActor.assumeIsolated { files.forEach(ImportCoordinator.shared.importFile) }
        return true
    }
}
