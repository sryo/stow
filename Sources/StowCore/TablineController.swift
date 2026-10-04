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

/// Tabline: the active workspace as a row of tabs riding whichever browser window is in
/// front. It never takes focus, so clicking a tab opens the site in the browser you're using.
///
/// Docking follows the window: 3pt above a floating window (below it when there's no room
/// above); a band under the menu bar for a window that fills the screen's height, nudging
/// the window down to make room; a thin lip at the top of a full-screen window that expands
/// while the pointer is over it.
///
/// The tab for the page in front is raised; tabs whose page is open in any browser carry a
/// live dot; a page not saved in the workspace gets a dashed ghost tab. Both come from
/// OpenTabsMonitor. The content follows the model through `bind(model:)`, so edits made
/// anywhere (Settings included) show up without being pushed.
@MainActor
final class TablineController {
    static let shared = TablineController()

    static let defaultsKey = "tablineEnabled"
    private static let height: CGFloat = 32
    private static let gap: CGFloat = 3
    private static let lipHeight: CGFloat = 5
    /// Room made under the menu bar for a window that fills the screen's height.
    private static let band: CGFloat = gap + height + gap

    var onOpenLink: ((Link) -> Void)?
    var onSelectWorkspace: ((UUID) -> Void)?
    var onStowURL: ((URL, String) -> Void)?
    var onToggleTask: ((UUID) -> Void)?
    /// When nil, clicking a snippet copies its content to the general pasteboard.
    var onCopySnippet: ((Snippet) -> Void)?
    var onSearch: (() -> Void)? { didSet { refreshStrip() } }
    /// Nudge a screen-height browser window down to make the band under the menu bar.
    var makesRoomForBand = true

    private var panel: NSPanel?
    private let strip = TablineStripView()
    private var trackTimer: Timer?
    private var hoverTimer: Timer?
    private var lastFrame: NSRect = .zero

    private weak var model: AppModel?
    private var modelSubscription: AnyCancellable?
    private var monitorSubscriptions: Set<AnyCancellable> = []
    private(set) var content = TablineContent(workspaceId: nil, name: "", colorId: .defaultColor(), nodes: [], workspaces: [])
    private var entries: [TablineEntry] = []
    private var pocketTasks: [TaskItem] = []
    private var pocketSnippets: [Snippet] = []

    private let monitor = OpenTabsMonitor.shared
    private var lastFrontBundleId: String?

    private enum Dock: Equatable { case above, below, inside, band, lip, peek }
    private var dock: Dock = .above
    private var lipFrame: NSRect = .zero
    private var peekFrame: NSRect = .zero
    private var isMenuOpen = false

    private struct Nudge {
        let window: AXUIElement
        let original: CGRect
        let nudged: CGRect
    }
    private var nudges: [Nudge] = []

    /// The stored switch. Change it through AppPreferences.setTabline so the sheet, the
    /// Settings page and the Window menu stay in step.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

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

    /// Starts or stops the strip without touching the stored switch (AppPreferences owns it).
    func setRunning(_ running: Bool) {
        running ? start() : stop()
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
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { TablineController.shared.track() }
        }
        track()
    }

    private func stop() {
        trackTimer?.invalidate()
        trackTimer = nil
        monitor.setDemand(.tabline, false)
        monitor.frontBundleId = nil
        lastFrontBundleId = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        panel?.orderOut(nil)
        restoreNudgedWindows()
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
        let nodes = Self.unarchived(content.nodes)
        entries = nodes.compactMap { node in
            switch node {
            case .link(let link): return .link(link)
            case .folder(let folder): return .group(folder, links: Self.links(in: folder.children))
            case .task, .snippet: return nil
            }
        }
        pocketTasks = []
        pocketSnippets = []
        Self.collectPocket(nodes, tasks: &pocketTasks, snippets: &pocketSnippets)
        refreshStrip()
    }

    private static func unarchived(_ nodes: [Node]) -> [Node] {
        nodes.compactMap { node in
            guard !node.isArchived else { return nil }
            if case .folder(var folder) = node {
                folder.children = unarchived(folder.children)
                return .folder(folder)
            }
            return node
        }
    }

    private static func links(in nodes: [Node]) -> [Link] {
        nodes.flatMap { node -> [Link] in
            switch node {
            case .link(let link): return [link]
            case .folder(let folder): return links(in: folder.children)
            case .task, .snippet: return []
            }
        }
    }

    private static func collectPocket(_ nodes: [Node], tasks: inout [TaskItem], snippets: inout [Snippet]) {
        for node in nodes {
            switch node {
            case .task(let task): tasks.append(task)
            case .snippet(let snippet): snippets.append(snippet)
            case .folder(let folder): collectPocket(folder.children, tasks: &tasks, snippets: &snippets)
            case .link: break
            }
        }
    }

    /// Recomputes raised, live and ghost from the latest browser state and redraws.
    private func refreshStrip() {
        var model = TablineStripModel()
        model.name = content.name
        model.colorId = content.colorId
        model.entries = entries
        model.pocketCount = pocketTasks.count + pocketSnippets.count
        model.showsSearch = onSearch != nil

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

    // MARK: - Clicks and menus

    private func activate(_ kind: TablineStripView.Kind, rect: NSRect) {
        switch kind {
        case .chip: popUp(workspaceMenu(), under: rect)
        case .tab(let i):
            if case .link(let link) = entries[i] { onOpenLink?(link) }
        case .group(let i):
            if case .group(let folder, _) = entries[i] { popUp(folderMenu(folder), under: rect) }
        case .ghost:
            guard let ghost = strip.model.ghost else { return }
            onStowURL?(ghost.url, ghost.title.isEmpty ? ghost.host : ghost.title)
        case .overflow: popUp(overflowMenu(), under: rect)
        case .search: onSearch?()
        case .pocket: popUp(pocketMenu(), under: rect, alignRight: true)
        }
    }

    private func popUp(_ menu: NSMenu, under rect: NSRect, alignRight: Bool = false) {
        menu.appearance = strip.effectiveAppearance
        isMenuOpen = true
        let x = alignRight ? rect.maxX - menu.size.width : rect.minX
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: rect.maxY + 6), in: strip)
        isMenuOpen = false
    }

    private func item(_ title: String, image: NSImage? = nil, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = TablineMenuItem(title: title, action: #selector(TablineMenuItem.fire), keyEquivalent: key)
        item.target = item
        item.handler = action
        item.image = image
        return item
    }

    private func workspaceMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Workspaces"))
        let list = content.workspaces.isEmpty
            ? [TablineContent.WorkspaceEntry(id: content.workspaceId ?? UUID(), name: content.name, colorId: content.colorId)]
            : content.workspaces
        for (i, ws) in list.enumerated() {
            let id = ws.id
            let entry = item(ws.name, image: Self.dot(ws.colorId), key: i < 9 ? "\(i + 1)" : "") {
                TablineController.shared.onSelectWorkspace?(id)
            }
            entry.keyEquivalentModifierMask = .command
            entry.state = ws.id == content.workspaceId || (content.workspaceId == nil && i == 0) ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    private static func dot(_ colorId: WorkspaceColorId) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            colorId.color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
    }

    private func linkItem(_ link: Link) -> NSMenuItem {
        item(link.title, image: TablineGlyph.menuImage(title: link.title, url: link.url, faviconPath: link.faviconPath)) {
            TablineController.shared.onOpenLink?(link)
        }
    }

    private func folderMenu(_ folder: Folder) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: folder.name))
        addNodes(folder.children, to: menu)
        return menu
    }

    private func addNodes(_ nodes: [Node], to menu: NSMenu) {
        for node in nodes {
            switch node {
            case .link(let link): menu.addItem(linkItem(link))
            case .folder(let sub):
                let parent = NSMenuItem(title: sub.name, action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                addNodes(sub.children, to: submenu)
                parent.submenu = submenu
                menu.addItem(parent)
            case .task, .snippet: break
            }
        }
    }

    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for i in strip.hiddenEntryIndices where entries.indices.contains(i) {
            switch entries[i] {
            case .link(let link): menu.addItem(linkItem(link))
            case .group(let folder, _):
                let parent = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu()
                addNodes(folder.children, to: submenu)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        return menu
    }

    private func pocketMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Pocket · \(content.name)"))
        for task in pocketTasks {
            let id = task.id
            let entry = item(task.title) { TablineController.shared.onToggleTask?(id) }
            entry.state = task.isCompleted ? .on : .off
            menu.addItem(entry)
        }
        if !pocketTasks.isEmpty && !pocketSnippets.isEmpty { menu.addItem(.separator()) }
        for snippet in pocketSnippets {
            let image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            let entry = item(snippet.title, image: image) {
                if let copy = TablineController.shared.onCopySnippet {
                    copy(snippet)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet.content, forType: .string)
                }
            }
            entry.toolTip = "Copy"
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: - Tracking the front browser window

    private func track() {
        guard let panel else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleId = front.bundleIdentifier,
              bundleId == ActiveBrowserTracker.shared.lastActiveBundleId,
              let window = frontWindow(of: front) else {
            if panel.isVisible { panel.orderOut(nil) }
            lastFrontBundleId = nil
            monitor.setDemand(.tabline, false)
            monitor.frontBundleId = nil
            return
        }
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
        let visible = screen?.visibleFrame ?? frame
        let h = Self.height, gap = Self.gap

        if window.isFullScreen {
            // The screen's top below the notch. Not the window's: Chrome's focused window in full
            // screen starts under its toolbar, which is a separate window.
            let full = screen?.frame ?? frame
            let top = full.maxY - (screen?.safeAreaInsets.top ?? 0)
            let inset = (full.width * 0.143).rounded()
            lipFrame = NSRect(x: full.minX + inset, y: top - 2 - Self.lipHeight, width: full.width - inset * 2, height: Self.lipHeight)
            peekFrame = NSRect(x: lipFrame.minX, y: top - 6 - h, width: lipFrame.width, height: h)
            if dock != .peek { dock = .lip }
            return dock == .peek ? peekFrame : lipFrame
        }
        if dock == .lip || dock == .peek { dock = .above }

        if nudges.contains(where: { CFEqual($0.window, window.element) && Self.close($0.nudged, axRect(frame)) }) {
            dock = .band
            return NSRect(x: frame.minX + 4, y: visible.maxY - gap - h, width: frame.width - 8, height: h)
        }
        let fillsHeight = abs(frame.maxY - visible.maxY) <= 2 && abs(frame.minY - visible.minY) <= 2
        if fillsHeight {
            if makesRoomForBand, nudge(window, visible: visible) {
                dock = .band
                return NSRect(x: frame.minX + 4, y: visible.maxY - gap - h, width: frame.width - 8, height: h)
            }
            dock = .inside
            return NSRect(x: frame.minX + 4, y: visible.maxY - gap - h, width: frame.width - 8, height: h)
        }
        let width = max(200, frame.width)
        if frame.maxY + gap + h <= visible.maxY {
            dock = .above
            return NSRect(x: frame.minX, y: frame.maxY + gap, width: width, height: h)
        }
        if frame.minY - gap - h >= visible.minY {
            dock = .below
            return NSRect(x: frame.minX, y: frame.minY - gap - h, width: width, height: h)
        }
        dock = .inside
        return NSRect(x: frame.minX + 4, y: frame.minY + 6, width: frame.width - 8, height: h)
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
        guard !isMenuOpen, lipFrame != .zero else { return }
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

    private func frontWindow(of app: NSRunningApplication) -> FrontWindow? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let element = windowRef as! AXUIElement
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
    private func nudge(_ window: FrontWindow, visible: NSRect) -> Bool {
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

/// An NSMenuItem that runs a closure.
private final class TablineMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}
