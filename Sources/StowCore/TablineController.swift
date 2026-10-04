import AppKit
import Combine

/// What the Tabline shows: the current workspace's top-level nodes plus the workspace list
/// for the chip's menu. Archived nodes are filtered out by the controller.
struct TablineContent {
    struct WorkspaceEntry {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
        init(id: UUID, name: String, colorId: WorkspaceColorId) {
            self.id = id
            self.name = name
            self.colorId = colorId
        }
    }

    var workspaceId: UUID?
    var name: String
    var colorId: WorkspaceColorId
    var nodes: [Node]
    var workspaces: [WorkspaceEntry]
}

/// When the Tabline tracks the browser window. Window moves, resizes and focus changes
/// arrive as Accessibility notifications; the poll is only a safety net, and it stops
/// entirely while no browser is running.
enum TablineTracking {
    static let fallbackInterval: TimeInterval = 1.0

    static func shouldPoll(running: [String?], browsers: Set<String>) -> Bool {
        running.contains { $0.map(browsers.contains) == true }
    }

    static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    static let windowNotifications = [kAXMovedNotification, kAXResizedNotification,
                                      kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification]
}

/// How the strip sits against the window: outside it (above or below), inside its bottom
/// edge, in a band made under the menu bar, or as a full-screen lip that peeks on hover.
enum TablineDock: Equatable { case above, below, inside, band, lip, peek }

/// Where the Tabline goes for a window, in AppKit screen coordinates (y up).
///
/// On the top edge: 3pt above a floating window (below it when there's no room above); a
/// band under the menu bar for a window that fills the screen's height, which wants the
/// window nudged down to make room; a thin lip at the top of a full-screen window that
/// expands while the pointer is over it.
///
/// On the bottom edge: 3pt below the window, or inside its bottom edge when the window
/// reaches the bottom of the screen (maximized and full screen included). It never moves
/// the window.
struct TablinePlacement: Equatable {
    static let height: CGFloat = 32
    static let gap: CGFloat = 3
    static let lipHeight: CGFloat = 5
    /// Room made under the menu bar for a window that fills the screen's height.
    static let band: CGFloat = gap + height + gap

    var dock: TablineDock
    var frame: NSRect
    /// The band wants the window's top edge moved down by `band`. If that fails, the same
    /// frame sits inside the window instead.
    var wantsNudge = false
    /// Full screen on top: the lip and the strip it expands into.
    var lipFrame: NSRect?
    var peekFrame: NSRect?

    static func place(edge: TablineEdge, window frame: NSRect, isFullScreen: Bool, screen: NSRect, visible: NSRect,
                      safeAreaTop: CGFloat = 0, alreadyNudged: Bool = false, peeking: Bool = false) -> TablinePlacement {
        let h = height
        let width = max(200, frame.width)
        switch edge {
        case .bottom:
            let floor = isFullScreen ? screen : frame
            if !isFullScreen, frame.minY - gap - h >= visible.minY {
                return TablinePlacement(dock: .below, frame: NSRect(x: frame.minX, y: frame.minY - gap - h, width: width, height: h))
            }
            let bottom = max(floor.minY, isFullScreen ? screen.minY : visible.minY)
            return TablinePlacement(dock: .inside, frame: NSRect(x: floor.minX + 4, y: bottom + gap, width: floor.width - 8, height: h))

        case .top:
            if isFullScreen {
                // The screen's top below the notch. Not the window's: Chrome's focused window in full
                // screen starts under its toolbar, which is a separate window.
                let top = screen.maxY - safeAreaTop
                let inset = (screen.width * 0.143).rounded()
                let lip = NSRect(x: screen.minX + inset, y: top - 2 - lipHeight, width: screen.width - inset * 2, height: lipHeight)
                let peek = NSRect(x: lip.minX, y: top - 6 - h, width: lip.width, height: h)
                return TablinePlacement(dock: peeking ? .peek : .lip, frame: peeking ? peek : lip, lipFrame: lip, peekFrame: peek)
            }
            let bandFrame = NSRect(x: frame.minX + 4, y: visible.maxY - gap - h, width: frame.width - 8, height: h)
            if alreadyNudged { return TablinePlacement(dock: .band, frame: bandFrame) }
            let fillsHeight = abs(frame.maxY - visible.maxY) <= 2 && abs(frame.minY - visible.minY) <= 2
            if fillsHeight { return TablinePlacement(dock: .band, frame: bandFrame, wantsNudge: true) }
            if frame.maxY + gap + h <= visible.maxY {
                return TablinePlacement(dock: .above, frame: NSRect(x: frame.minX, y: frame.maxY + gap, width: width, height: h))
            }
            if frame.minY - gap - h >= visible.minY {
                return TablinePlacement(dock: .below, frame: NSRect(x: frame.minX, y: frame.minY - gap - h, width: width, height: h))
            }
            return TablinePlacement(dock: .inside, frame: NSRect(x: frame.minX + 4, y: frame.minY + 6, width: frame.width - 8, height: h))
        }
    }
}

/// Tabline: the active workspace as a row of tabs riding whichever browser window is in
/// front. It never takes focus, so clicking a tab opens the site in the browser you're using.
/// It docks on the window's top or bottom edge, as `TablinePlacement` lays out.
///
/// The tab for the page in front is raised; tabs whose page is open in any browser carry a
/// live dot; a page not saved in the workspace gets a dashed ghost tab. Both come from
/// OpenTabsMonitor. The content follows the model through `bind(model:)`, so edits made
/// anywhere (Settings included) show up without being pushed.
///
/// The ⌕ search tool from the mockup isn't drawn: searching lives in the sidebar.
@MainActor
final class TablineController {
    static let shared = TablineController()

    static let defaultsKey = "tablineEnabled"
    /// Which edge the strip rides, "top" or "bottom". AppPreferences writes it from the dock.
    static let edgeKey = "tablineEdge"
    private static let height = TablinePlacement.height
    private static let band = TablinePlacement.band

    var onOpenLink: ((Link) -> Void)?
    var onSelectWorkspace: ((UUID) -> Void)?
    /// Stows the ghost tab; the result says whether it was new or already saved.
    var onStowURL: ((URL, String) -> AppModel.StowResult?)?
    var onToggleTask: ((UUID) -> Void)?
    /// When nil, clicking a snippet copies its content to the general pasteboard.
    var onCopySnippet: ((Snippet) -> Void)?
    /// A group's "Open all". When nil, each of its links opens through `onOpenLink`.
    var onOpenFolder: ((Folder) -> Void)?
    /// A right-click on the chip: the workspace's WorkspaceMenu, shown in `view` at `rect`.
    var onWorkspaceContextMenu: ((UUID, NSView, NSRect) -> Void)?
    /// "Edit Workspace…" from the chip's list: the shared workspace editor, anchored on
    /// the chip (`rect` in `view`).
    var onEditWorkspace: ((UUID, NSView, NSRect) -> Void)?

    private var panel: NSPanel?
    private let strip = TablineStripView()
    private var trackTimer: Timer?
    private var hoverTimer: Timer?
    private var lastFrame: NSRect = .zero
    private var isRunning = false
    private var trackScheduled = false
    private var axObserver: AXNotificationObserver?
    private var observedWindow: AXUIElement?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var browserIds: Set<String> = []

    private weak var model: AppModel?
    private var modelSubscription: AnyCancellable?
    private var monitorSubscriptions: Set<AnyCancellable> = []
    private(set) var content = TablineContent(workspaceId: nil, name: "", colorId: .defaultColor(), nodes: [], workspaces: [])
    private var entries: [TablineEntry] = []
    private var pocket = Pocket.Contents()
    /// The group, overflow, pocket and workspace lists, below the strip.
    private let flyout = FlyoutListPresenter(takesKey: false)
    /// The gear's app sheet.
    private lazy var settings: TablineSettingsFlyout = {
        let settings = TablineSettingsFlyout()
        settings.onClose = { TablineController.shared.flyoutsClosed() }
        return settings
    }()
    private var isSettingsOpen: Bool { settingsLoaded && settings.isOpen }
    private var settingsLoaded = false
    private var outsideClickMonitor: Any?

    private enum OpenList: Hashable { case chip, group(UUID), overflow, pocket }

    private let monitor = OpenTabsMonitor.shared
    private var lastFrontBundleId: String?

    private var dock: TablineDock = .above
    private var edge: TablineEdge = .top

    /// Where the strip's flyouts open: away from the edge it rides.
    static func flyoutEdge(for edge: TablineEdge) -> FlyoutPanel.Edge {
        edge == .top ? .below : .above
    }

    /// The edge the strip's flyouts and the workspace editor open toward right now.
    var flyoutEdge: FlyoutPanel.Edge { Self.flyoutEdge(for: edge) }
    private var lipFrame: NSRect = .zero
    private var peekFrame: NSRect = .zero

    private struct Nudge {
        let window: AXUIElement
        let original: CGRect
        let nudged: CGRect
    }
    private var nudges: [Nudge] = []


    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TablineController.shared.restoreNudgedWindows() }
        }
    }

    /// Follows `model`: the active workspace's items and the workspace list, refreshed on
    /// every change.
    func bind(model: AppModel) {
        self.model = model
        modelSubscription = model.changes.sink { _ in
            MainActor.assumeIsolated { TablineController.shared.reload() }
        }
        reload()
    }

    func startIfEnabled() {
        AppPreferences.shared.applyPendingTabline()
    }

    /// Runs the strip on `edge`, or stops it with nil, without touching the stored dock
    /// (AppPreferences owns it).
    func setRunning(edge: TablineEdge?) {
        guard let edge else { return stop() }
        if edge != self.edge {
            closeFlyouts()
            self.edge = edge
            restoreNudgedWindows()
            dock = .above
            lastFrame = .zero
        }
        start()
    }

    private func start() {
        if !AXIsProcessTrusted() {
            // Reading the browser window's frame needs Accessibility; prompt the same way attach mode does.
            WindowAttachmentService.shared.requestAccessibilityPermissions()
        }
        if panel == nil { makePanel() }
        reload()
        if monitorSubscriptions.isEmpty {
            monitor.$openKeys.removeDuplicates().dropFirst().sink { _ in
                MainActor.assumeIsolated { TablineController.shared.refreshStripSoon() }
            }.store(in: &monitorSubscriptions)
            monitor.$frontPage.removeDuplicates().dropFirst().sink { _ in
                MainActor.assumeIsolated { TablineController.shared.refreshStripSoon() }
            }.store(in: &monitorSubscriptions)
        }
        isRunning = true
        if workspaceObservers.isEmpty { observeWorkspace() }
        refreshBrowserIds()
        updatePolling()
    }

    private func stop() {
        closeFlyouts()
        isRunning = false
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers = []
        pauseTracking()
        restoreNudgedWindows()
    }

    /// Stops every timer and observer and hides the strip, until a browser runs again.
    private func pauseTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        stopObservingWindows()
        hidePanel()
    }

    private func hidePanel() {
        closeFlyouts()
        if panel?.isVisible == true { panel?.orderOut(nil) }
        lastFrontBundleId = nil
        monitor.setDemand(.tabline, false)
        monitor.frontBundleId = nil
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let launchedOrQuit = { (note: Notification) in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { TablineController.shared.appsChanged(launched: note.name == NSWorkspace.didLaunchApplicationNotification ? bundleId : nil) }
        }
        let retrack = { (_: Notification) in
            MainActor.assumeIsolated { TablineController.shared.scheduleTrack() }
        }
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: launchedOrQuit),
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: launchedOrQuit),
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: retrack),
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: retrack),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: retrack),
        ]
    }

    private func refreshBrowserIds() {
        browserIds = Set(BrowserManager.installedBrowsers().map(\.bundleId))
        browserIds.remove(Bundle.main.bundleIdentifier ?? "")
    }

    private func appsChanged(launched bundleId: String?) {
        guard isRunning else { return }
        // A browser installed since the last look.
        if let bundleId, !browserIds.contains(bundleId) { refreshBrowserIds() }
        updatePolling()
    }

    /// Runs the slow fallback poll while any browser is running and pauses everything otherwise.
    private func updatePolling() {
        guard isRunning else { return }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.bundleIdentifier)
        guard TablineTracking.shouldPoll(running: running, browsers: browserIds) else {
            pauseTracking()
            return
        }
        if trackTimer == nil {
            trackTimer = Timer.scheduledTimer(withTimeInterval: TablineTracking.fallbackInterval, repeats: true) { _ in
                MainActor.assumeIsolated { TablineController.shared.track() }
            }
        }
        track()
    }

    /// Coalesces bursts (a window drag sends a stream of moves) into one track per run loop
    /// turn, and lets other observers of the same notification, such as ActiveBrowserTracker,
    /// update first.
    private func scheduleTrack() {
        guard isRunning, trackTimer != nil, !trackScheduled else { return }
        trackScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let controller = TablineController.shared
                controller.trackScheduled = false
                guard controller.isRunning, controller.trackTimer != nil else { return }
                controller.track()
            }
        }
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        strip.onActivate = { kind, rect in TablineController.shared.activate(kind, rect: rect) }
        strip.onContextMenu = { kind, rect in TablineController.shared.showContextMenu(kind, rect: rect) }
        wireFlyout()
        panel.contentView = strip
        self.panel = panel
    }

    // MARK: - Content

    /// Refreshes the tabs from the model's active workspace.
    func reload() {
        guard let model else { return }
        let ws = model.activeWorkspace
        content = TablineContent(workspaceId: ws.id, name: ws.name, colorId: ws.colorId, nodes: ws.items,
                                 workspaces: model.workspaces.map { .init(id: $0.id, name: $0.name, colorId: $0.colorId) })
        entries = content.nodes.unarchived().compactMap { node in
            switch node {
            case .link(let link): return .link(link)
            case .folder(let folder): return .group(folder, links: folder.children.flattenLinks())
            case .task, .snippet: return nil
            }
        }
        pocket = Pocket.collect(content.nodes)
        refreshStrip()
        refreshOpenList()
    }

    /// Recomputes raised, live and ghost from the latest browser state and redraws.
    private func refreshStrip() {
        var model = TablineStripModel()
        model.name = content.name
        model.colorId = content.colorId
        model.entries = entries
        model.pocketCount = pocket.count

        model.liveIndices = Self.liveIndices(entries: entries, openKeys: monitor.openKeys)
        if let page = monitor.frontPage, page.bundleId == lastFrontBundleId {
            if let raised = bestEntry(for: page.url) {
                model.raisedIndex = raised
            } else if let scheme = page.url.scheme, scheme == "http" || scheme == "https" {
                let host = TablineGlyph.host(of: page.url.absoluteString)
                if !host.isEmpty { model.ghost = TablineGhost(url: page.url, title: page.title, host: host) }
            }
        }
        strip.update(model)
        panel?.invalidateShadow()
    }

    /// Links whose exact page (by canonical URL) is open in a browser. Folders get no dot.
    static func liveIndices(entries: [TablineEntry], openKeys: Set<String>) -> Set<Int> {
        Set(entries.indices.filter { i in
            guard case .link(let link) = entries[i], let key = URLCanonical.key(link.url) else { return false }
            return openKeys.contains(key)
        })
    }

    /// `@Published` sinks run before the value is stored, so redraw once it is.
    private func refreshStripSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { TablineController.shared.refreshStrip() } }
    }

    /// The entry whose site is the page in front: an exact URL wins, then the longest
    /// saved path that prefixes the page's path, then any link on the same host.
    private func bestEntry(for url: URL) -> Int? {
        let host = TablineGlyph.host(of: url.absoluteString)
        guard !host.isEmpty else { return nil }
        let canonical = URLCanonical.key(url)
        let path = url.path
        var best: (index: Int, score: Int)?
        for (i, entry) in entries.enumerated() {
            for link in entry.links {
                guard let linkURL = URL(string: link.url), TablineGlyph.host(of: link.url) == host else { continue }
                var score = 1
                if URLCanonical.key(linkURL) == canonical {
                    score = 10_000
                } else if !linkURL.path.isEmpty, linkURL.path != "/", path.hasPrefix(linkURL.path) {
                    score = 10 + linkURL.path.count
                }
                if score > (best?.score ?? 0) { best = (i, score) }
            }
        }
        return best?.index
    }

    // MARK: - Clicks and flyouts

    private func activate(_ kind: TablineStripView.Kind, rect: NSRect) {
        if kind != .gear, isSettingsOpen { settings.close() }
        switch kind {
        case .gear: toggleSettings(from: rect)
        case .chip: showList(.chip, under: rect)
        case .tab(let i):
            flyout.closeAll()
            if case .link(let link) = entries[i] { onOpenLink?(link) }
        case .group(let i):
            if case .group(let folder, _) = entries[i] { showList(.group(folder.id), under: rect) }
        case .ghost:
            flyout.closeAll()
            guard let ghost = strip.model.ghost else { return }
            let result = onStowURL?(ghost.url, ghost.title.isEmpty ? ghost.host : ghost.title)
            if let message = result.flatMap(stowMessage) { showToast(message, duration: Toast.briefDuration * 2) }
        case .overflow: showList(.overflow, under: rect)
        case .pocket: showList(.pocket, under: rect)
        }
    }

    /// Only the chip has a right-click menu: the native WorkspaceMenu for the workspace
    /// the Tabline shows.
    private func showContextMenu(_ kind: TablineStripView.Kind, rect: NSRect) {
        guard kind == .chip, let id = content.workspaceId else { return }
        closeFlyouts()
        onWorkspaceContextMenu?(id, strip, rect)
    }

    /// "Stowed in Research" or "Already in Research", for the toast under the strip.
    private func stowMessage(_ result: AppModel.StowResult) -> String? {
        switch result {
        case .added:
            return "Stowed in \(content.name)"
        case .alreadyPresent(let id):
            let name = model?.workspaces.first { $0.items.flattenIds().contains(id) }?.name ?? content.name
            return "Already in \(name)"
        }
    }

    /// The toast floats under the strip, since Stow's own window may be hidden.
    private func showToast(_ message: String, duration: TimeInterval = Toast.briefDuration) {
        Toast.show(message, in: panel, duration: duration, placement: .below)
    }

    /// Opens the list for a strip item below it, or closes it when it's already open.
    private func showList(_ id: OpenList, under rect: NSRect) {
        guard let panel, let content = listContent(for: id) else { return }
        flyout.toggle(id: id) {
            let list = FlyoutListView(title: content.title, detail: content.detail, sections: content.sections,
                                      footer: content.footer)
            let anchor = panel.convertToScreen(strip.convert(rect, to: nil))
            // The Tabline never takes focus from the browser: its lists are for the pointer.
            flyout.show(list, id: id, anchor: anchor, edge: flyoutEdge, topInset: 0, parent: panel, takeKeyboard: false)
            installOutsideClickMonitor()
        }
    }

    private struct ListContent {
        var title: String
        var detail: String?
        var sections: [FlyoutListSection]
        var footer: [FlyoutListView.FooterButton] = []
    }

    private func listContent(for id: OpenList) -> ListContent? {
        let openKeys = monitor.openKeys
        switch id {
        case .chip:
            let list = content.workspaces.isEmpty
                ? [TablineContent.WorkspaceEntry(id: content.workspaceId ?? UUID(), name: content.name, colorId: content.colorId)]
                : content.workspaces
            let rows = FlyoutListModel.rows(forWorkspaces: list.map { ($0.id, $0.name, $0.colorId) },
                                            current: content.workspaceId ?? list.first?.id,
                                            shortcut: { WorkspaceShortcut.label(position: $0) })
            return ListContent(title: "Workspaces", detail: nil, sections: [FlyoutListSection(title: nil, rows: rows)],
                               footer: Self.chipFooter { TablineController.shared.editWorkspace() })
        case .group(let folderId):
            guard let folder = entries.lazy.compactMap({ entry -> Folder? in
                if case .group(let f, _) = entry, f.id == folderId { return f }
                return nil
            }).first else { return nil }
            let rows = FlyoutListModel.rows(for: folder, openKeys: openKeys)
            let openAll = FlyoutListView.FooterButton(title: "Open all  ⌥↩", style: .primary) {
                TablineController.shared.openAll(folder)
                TablineController.shared.flyout.closeAll()
            }
            return ListContent(title: folder.name, detail: "\(rows.count)", sections: [FlyoutListSection(title: nil, rows: rows)],
                               footer: folder.children.flattenLinks().isEmpty ? [] : [openAll])
        case .overflow:
            let nodes: [Node] = strip.hiddenEntryIndices.filter(entries.indices.contains).map { i in
                switch entries[i] {
                case .link(let link): return .link(link)
                case .group(let folder, _): return .folder(folder)
                }
            }
            guard !nodes.isEmpty else { return nil }
            let rows = FlyoutListModel.rows(for: nodes, openKeys: openKeys)
            return ListContent(title: content.name, detail: "\(rows.count) more", sections: [FlyoutListSection(title: nil, rows: rows)])
        case .pocket:
            guard !pocket.isEmpty else { return nil }
            return ListContent(title: "Pocket", detail: content.name, sections: Self.pocketSections(pocket))
        }
    }

    /// The chip's list ends with a way into the workspace editor, as the rail's dots have.
    static func chipFooter(edit: @escaping () -> Void) -> [FlyoutListView.FooterButton] {
        [FlyoutListView.FooterButton(title: "Edit Workspace…", action: edit)]
    }

    private func editWorkspace() {
        flyout.closeAll()
        guard let id = content.workspaceId, let rect = strip.rect(of: .chip) else { return }
        onEditWorkspace?(id, strip, rect)
    }

    // MARK: - Settings

    /// The gear opens the app sheet under it (over it on the bottom edge), or closes it.
    private func toggleSettings(from rect: NSRect) {
        guard let panel else { return }
        flyout.closeAll()
        settingsLoaded = true
        let anchor = panel.convertToScreen(strip.convert(rect, to: nil))
        settings.toggle(anchor: anchor, edge: edge, parent: panel, colorId: content.colorId)
        if settings.isOpen { installOutsideClickMonitor() }
    }

    private func closeFlyouts() {
        flyout.closeAll()
        if settingsLoaded { settings.close() }
    }

    private var anyFlyoutOpen: Bool { flyout.isOpen || isSettingsOpen }

    private func flyoutsClosed() {
        if !anyFlyoutOpen { removeOutsideClickMonitor() }
    }

    /// Tasks, then snippets. The Tabline has no task or snippet editor, so rows carry no
    /// trailing buttons and there's no "New task".
    static func pocketSections(_ pocket: Pocket.Contents) -> [FlyoutListSection] {
        func plain(_ rows: [FlyoutListRow]) -> [FlyoutListRow] {
            rows.map { row in
                var row = row
                row.secondary = nil
                row.hoverTrailing = nil
                return row
            }
        }
        var sections: [FlyoutListSection] = []
        if !pocket.tasks.isEmpty {
            sections.append(FlyoutListSection(title: nil, rows: plain(FlyoutListModel.rows(for: pocket.tasks, newTask: false))))
        }
        if !pocket.snippets.isEmpty {
            sections.append(FlyoutListSection(title: pocket.tasks.isEmpty ? nil : "Snippets",
                                              rows: plain(FlyoutListModel.rows(for: pocket.snippets))))
        }
        return sections
    }

    /// Re-reads the open list after the model changed: a task toggled in the pocket.
    private func refreshOpenList() {
        guard let id = flyout.rootId as? OpenList else { return }
        guard let content = listContent(for: id) else { flyout.closeAll(); return }
        flyout.refreshRoot(title: content.title, detail: content.detail, sections: content.sections)
    }

    private func openAll(_ folder: Folder) {
        if let onOpenFolder {
            onOpenFolder(folder)
        } else {
            folder.children.unarchived().flattenLinks().forEach { onOpenLink?($0) }
        }
    }

    private func wireFlyout() {
        flyout.onOpenAll = { folder in TablineController.shared.openAll(folder) }
        flyout.onClose = { TablineController.shared.flyoutsClosed() }
        flyout.onAction = { action, _, _ in
            let controller = TablineController.shared
            switch action {
            case .openLink(let id):
                if let link = controller.content.nodes.flattenLinks().first(where: { $0.id == id }) { controller.onOpenLink?(link) }
            case .toggleTask(let id):
                controller.onToggleTask?(id)
            case .copySnippet(let id):
                guard let snippet = controller.pocket.snippets.first(where: { $0.id == id }) else { return }
                if let copy = controller.onCopySnippet {
                    copy(snippet)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet.content, forType: .string)
                }
                controller.showToast("Copied")
            case .selectWorkspace(let id):
                controller.onSelectWorkspace?(id)
            case .pushFolder, .newTask, .setDueDate, .editSnippet:
                break
            }
        }
    }

    /// Clicks in the browser below never reach Stow's local monitor; close on those too.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { TablineController.shared.closeFlyouts() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Tracking the front browser window

    private func track() {
        guard let panel else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleId = front.bundleIdentifier,
              bundleId == ActiveBrowserTracker.shared.lastActiveBundleId,
              let window = frontWindow(of: front) else {
            hidePanel()
            return
        }
        observe(app: front, window: window.element)
        if bundleId != lastFrontBundleId {
            lastFrontBundleId = bundleId
            monitor.frontBundleId = bundleId
            refreshStrip()
        }
        monitor.setDemand(.tabline, true)
        let target = placement(for: window)
        setPanelFrame(target)
        updateHoverTimer()
    }

    private func setPanelFrame(_ target: NSRect) {
        guard let panel else { return }
        strip.isLip = dock == .lip
        if target != lastFrame || !panel.isVisible {
            lastFrame = target
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
            panel.orderFrontRegardless()
        }
    }

    private struct FrontWindow {
        let element: AXUIElement
        let frame: NSRect
        let isFullScreen: Bool
    }

    private func placement(for window: FrontWindow) -> NSRect {
        let frame = window.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let alreadyNudged = edge == .top
            && nudges.contains { CFEqual($0.window, window.element) && Self.close($0.nudged, axRect(frame)) }
        let placed = TablinePlacement.place(edge: edge, window: frame, isFullScreen: window.isFullScreen,
                                            screen: screen?.frame ?? frame, visible: screen?.visibleFrame ?? frame,
                                            safeAreaTop: screen?.safeAreaInsets.top ?? 0, alreadyNudged: alreadyNudged,
                                            peeking: dock == .peek)
        lipFrame = placed.lipFrame ?? .zero
        peekFrame = placed.peekFrame ?? .zero
        dock = placed.dock
        if placed.wantsNudge, !nudge(window) {
            // Same frame, laid over the window's top instead.
            dock = .inside
        }
        return placed.frame
    }

    // MARK: - Full-screen lip

    private func updateHoverTimer() {
        let needsHover = dock == .lip || dock == .peek
        if needsHover, hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
                MainActor.assumeIsolated { TablineController.shared.checkLipHover() }
            }
        } else if !needsHover {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func checkLipHover() {
        // The peek stays out while a list or the app sheet hangs off it.
        guard !anyFlyoutOpen, lipFrame != .zero else { return }
        let mouse = NSEvent.mouseLocation
        switch dock {
        case .lip:
            // From just under the lip up through the notch band to the screen's top edge.
            let hotzone = NSRect(x: lipFrame.minX, y: lipFrame.minY - 8, width: lipFrame.width, height: 120)
            if hotzone.contains(mouse) {
                dock = .peek
                setPanelFrame(peekFrame)
            }
        case .peek:
            if !peekFrame.insetBy(dx: -12, dy: -12).contains(mouse) {
                dock = .lip
                setPanelFrame(lipFrame)
            }
        default: break
        }
    }

    // MARK: - Accessibility

    /// Follows the browser's focused-window changes and the front window's moves and resizes.
    private func observe(app: NSRunningApplication, window: AXUIElement) {
        let pid = app.processIdentifier
        if axObserver?.pid != pid {
            stopObservingWindows()
            // Registration fails until Accessibility is granted; the fallback poll retries.
            guard let observer = AXNotificationObserver(pid: pid, handler: { _, _ in TablineController.shared.scheduleTrack() }),
                  observer.add(TablineTracking.appNotifications, to: AXHelper.application(pid)) else { return }
            axObserver = observer
        }
        guard let axObserver else { return }
        if let observedWindow, CFEqual(observedWindow, window) { return }
        if let observedWindow { axObserver.remove(TablineTracking.windowNotifications, from: observedWindow) }
        observedWindow = axObserver.add(TablineTracking.windowNotifications, to: window) ? window : nil
    }

    private func stopObservingWindows() {
        if let observedWindow { axObserver?.remove(TablineTracking.windowNotifications, from: observedWindow) }
        observedWindow = nil
        axObserver = nil
    }

    private func frontWindow(of app: NSRunningApplication) -> FrontWindow? {
        let appElement = AXHelper.application(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let element = AXHelper.bounded(windowRef as! AXUIElement)
        guard let rect = axFrame(element) else { return nil }
        var fullRef: CFTypeRef?
        let isFullScreen = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullRef) == .success
            && (fullRef as? Bool) == true
        return FrontWindow(element: element, frame: cocoaRect(rect), isFullScreen: isFullScreen)
    }

    /// Frame in Accessibility coordinates (top-left origin on the primary display).
    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef, let size = sizeRef else { return nil }
        var point = CGPoint.zero, cgSize = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
        return CGRect(origin: point, size: cgSize)
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    private func cocoaRect(_ ax: CGRect) -> NSRect { NSRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height) }
    private func axRect(_ cocoa: NSRect) -> CGRect { CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height) }
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    private func setAXFrame(_ element: AXUIElement, _ rect: CGRect) -> Bool {
        var origin = rect.origin, size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position) == .success
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue) == .success
        return moved && resized
    }

    /// Moves the window's top edge down by the band height. Remembered so it can be undone.
    private func nudge(_ window: FrontWindow) -> Bool {
        let original = axRect(window.frame)
        var target = original
        target.origin.y += Self.band
        target.size.height -= Self.band
        guard target.height > 200, setAXFrame(window.element, target) else { return false }
        let actual = axFrame(window.element) ?? target
        nudges.removeAll { CFEqual($0.window, window.element) }
        nudges.append(Nudge(window: window.element, original: original, nudged: actual))
        return true
    }

    /// Gives nudged windows their room back, unless they've since been moved or resized.
    func restoreNudgedWindows() {
        for nudge in nudges {
            guard let current = axFrame(nudge.window), Self.close(current, nudge.nudged) else { continue }
            _ = setAXFrame(nudge.window, nudge.original)
        }
        nudges.removeAll()
    }
}
