//
//  SettingsContentViewController.swift
//  Stow
//

import AppKit
import UniformTypeIdentifiers

/// The Settings page: the workspace list first, then Appearance, Window, Shortcut,
/// Browser and Import.
///
/// It adapts to the width the main window gives it:
/// - rail (under 120pt): a column of section buttons, each opening its section in a
///   popover, with the workspaces stacked as icons under the Workspaces button;
/// - list (120–260pt): the page, with rows whose controls wrap below their labels;
/// - sidebar and wider: the page with every control inline.
///
/// Layout is done with frames, top to bottom, so nothing here imposes a minimum width
/// on the container.
@MainActor
final class SettingsContentViewController: NSViewController {

    enum WidthMode: Equatable {
        case rail, list, sidebar

        static func forWidth(_ width: CGFloat) -> WidthMode {
            if width < 120 { return .rail }
            if width < 260 { return .list }
            return .sidebar
        }
    }

    enum Section: CaseIterable {
        case workspaces, appearance, window, shortcut, browser, importing

        var title: String {
            switch self {
            case .workspaces: return "Workspaces"
            case .appearance: return "Appearance"
            case .window: return "Window"
            case .shortcut: return "Shortcut"
            case .browser: return "Browser"
            case .importing: return "Import"
            }
        }

        var symbolName: String {
            switch self {
            case .workspaces: return "rectangle.stack"
            case .appearance: return "paintpalette"
            case .window: return "macwindow"
            case .shortcut: return "command"
            case .browser: return "globe"
            case .importing: return "square.and.arrow.down"
            }
        }
    }

    static let visibleWorkspaceLimit = 6

    // MARK: Model

    weak var appModel: AppModel? {
        didSet { reloadWorkspaces() }
    }

    /// Called by MainViewController when workspaces change.
    func notifyWorkspacesChanged() {
        reloadWorkspaces()
    }

    // MARK: Views

    private let scrollView = NSScrollView()
    private let pageView = FlippedView()
    private let railView = FlippedView()
    private var groups: [Section: SettingsGroupView] = [:]
    private(set) var widthMode: WidthMode = .sidebar

    // Workspaces
    private let workspaceCollectionView = WorkspaceListCollectionView()
    private let workspaceDropIndicator = WorkspaceDropIndicatorView()
    private let showMoreRow = SettingsActionRow(title: "Show more", symbolName: "chevron.down")
    private let newWorkspaceRow = SettingsActionRow(title: "New workspace", symbolName: "plus")
    private var showsAllWorkspaces = false
    private var pendingRenameId: UUID?
    private var renamingWorkspaceId: UUID?
    private var needsReloadAfterRename = false

    // Appearance
    private var pageThumbnails: [PageThumbnailView] = []
    private var tintControl: SettingsSegmentedControl!
    private let tintHelp = SettingsStatusLine()

    // Window
    private var windowModeControl: SettingsSegmentedControl!
    private let windowHelp = SettingsStatusLine()
    private var permissionRow: SettingsRow!
    private var browserSideControl: SettingsSegmentedControl!
    private var browserSideRow: SettingsRow!
    private let preferences = AppPreferences.shared

    // Shortcut
    private let shortcutRecorderView = FlyoutShortcutRecorder(action: .toggleStow)
    private let shortcutStatus = SettingsStatusLine()

    // Browser
    private let browserPopUp = SettingsPopUp()
    private var browsers: [AppPreferences.BrowserChoice] = []

    // Import
    private let arcImportButton = SettingsButton(title: "Import…", accessibilityLabel: "Import from Arc…")
    private let fileImportButton = SettingsButton(title: "Import…", accessibilityLabel: "Import workspace file…")
    private let arcImportStatus = SettingsStatusLine()
    private let fileImportStatus = SettingsStatusLine()

    // Rail
    private var railButtons: [Section: SettingsIconButton] = [:]
    private var railWorkspaceChips: [NSView] = []
    private var popover: NSPopover?
    private var popoverSection: Section?

    private var keyViewLoopScheduled = false

    // MARK: Lifecycle

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        setupWorkspaceList()
        buildGroups()
        buildRail()
        loadBrowsers()
        reloadWorkspaces()
        updateWindowSection()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(scrollBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(tintModeChangedElsewhere), name: .stowTintModeChanged, object: nil)
        center.addObserver(self, selector: #selector(windowSettingsChangedElsewhere), name: .alwaysOnTopSettingChanged, object: nil)
        center.addObserver(self, selector: #selector(windowSettingsChangedElsewhere), name: .attachmentSettingChanged, object: nil)
        center.addObserver(self, selector: #selector(preferencesChangedElsewhere), name: .stowAppPreferencesChanged, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowSection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let mode = WidthMode.forWidth(view.bounds.width)
        if mode != widthMode {
            widthMode = mode
            applyWidthMode()
        }
        relayout()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Setup

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = pageView
        scrollView.contentView.postsBoundsChangedNotifications = true
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupWorkspaceList() {
        let layout = ListFlowLayout(metrics: ListMetrics())
        workspaceCollectionView.collectionViewLayout = layout
        workspaceCollectionView.dataSource = self
        workspaceCollectionView.delegate = self
        workspaceCollectionView.isSelectable = true // needed for drag and drop
        workspaceCollectionView.allowsMultipleSelection = false
        workspaceCollectionView.backgroundColors = [.clear]
        workspaceCollectionView.register(WorkspaceCollectionViewItem.self, forItemWithIdentifier: Self.workspaceItemId)
        workspaceCollectionView.registerForDraggedTypes([workspacePasteboardType])
        workspaceCollectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        workspaceDropIndicator.translatesAutoresizingMaskIntoConstraints = true
        workspaceCollectionView.addSubview(workspaceDropIndicator)

        showMoreRow.target = self
        showMoreRow.action = #selector(toggleShowAllWorkspaces)
        newWorkspaceRow.target = self
        newWorkspaceRow.action = #selector(createWorkspace)
    }

    private static let workspaceItemId = NSUserInterfaceItemIdentifier("WorkspaceItem")

    private func buildGroups() {
        // Workspaces
        let workspaces = SettingsGroupView(section: .workspaces)
        workspaces.add(workspaceCollectionView) { [weak self] in self?.workspaceListHeight ?? 0 }
        workspaces.add(showMoreRow)
        workspaces.add(newWorkspaceRow)

        // Appearance
        let tints = StowTheme.TintMode.allCases
        pageThumbnails = tints.map { PageThumbnailView(tint: $0) }
        let tintTitles: [StowTheme.TintMode: String] = [.full: "Full", .subtle: "Subtle", .off: "Off"]
        tintControl = SettingsSegmentedControl(
            segments: tints.enumerated().map { index, tint in
                .init(title: tintTitles[tint] ?? tint.rawValue, leadingView: pageThumbnails[index], accessibilityHint: Self.tintHelpText(tint))
            },
            selectedIndex: tints.firstIndex(of: StowTheme.preferredTint) ?? 0,
            accessibilityLabel: "Page color"
        )
        tintControl.onChange = { [weak self] index in self?.tintModeChanged(index) }
        tintHelp.set(Self.tintHelpText(StowTheme.preferredTint))
        let appearance = SettingsGroupView(section: .appearance)
        appearance.add(SettingsRow(title: "Page color", control: tintControl))
        appearance.add(tintHelp)

        // Window
        windowModeControl = SettingsSegmentedControl(
            segments: [
                .init(title: "Floating", leadingView: Self.glyph("macwindow"), accessibilityHint: "A regular window you can place anywhere."),
                .init(title: "On top", leadingView: Self.glyph("macwindow.on.rectangle"), accessibilityHint: "Stays above every other app."),
                .init(title: "Attached", leadingView: Self.glyph("sidebar.left"), accessibilityHint: "Sits beside your browser window. Needs Accessibility access."),
            ],
            selectedIndex: currentWindowMode.rawValue,
            accessibilityLabel: "Window"
        )
        windowModeControl.fillsWidth = true
        windowModeControl.onChange = { [weak self] index in
            self?.windowModeChanged(AppWindowMode(rawValue: index) ?? .floating)
        }

        let openSettings = SettingsButton(title: "Open Settings", accessibilityLabel: "Open System Settings…")
        openSettings.target = self
        openSettings.action = #selector(openAccessibilitySettings)
        permissionRow = SettingsRow(title: "Needs Accessibility", control: openSettings, symbolName: "exclamationmark.triangle.fill")
        permissionRow.label.toolTip = "Stow needs Accessibility access to attach to your browser window. Allow it in System Settings › Privacy & Security › Accessibility."

        browserSideControl = SettingsSegmentedControl(
            segments: [.init(title: "Left"), .init(title: "Right")],
            selectedIndex: preferences.browserSide,
            accessibilityLabel: "Browser side"
        )
        browserSideControl.onChange = { [weak self] index in self?.browserSideChanged(index) }
        browserSideRow = SettingsRow(title: "Browser side", control: browserSideControl)

        let window = SettingsGroupView(section: .window)
        window.add(SettingsRow(fullWidthControl: windowModeControl))
        window.add(windowHelp)
        window.add(permissionRow)
        window.add(browserSideRow)

        // Shortcut
        shortcutRecorderView.onShortcutChanged = {
            NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
        }
        shortcutRecorderView.onStatusChanged = { [weak self] text, kind in
            self?.shortcutStatus.set(text, kind: kind == .danger ? .danger : (kind == .success ? .success : .help))
            self?.relayout()
        }
        let shortcut = SettingsGroupView(section: .shortcut)
        shortcut.add(SettingsRow(title: "Toggle Stow", control: shortcutRecorderView))
        shortcut.add(shortcutStatus)

        // Browser
        browserPopUp.popup.target = self
        browserPopUp.popup.action = #selector(browserChanged)
        browserPopUp.popup.setAccessibilityLabel("Open links in")
        let browser = SettingsGroupView(section: .browser)
        browser.add(SettingsRow(title: "Open links in", control: browserPopUp))

        // Import
        arcImportButton.target = self
        arcImportButton.action = #selector(importFromArc)
        fileImportButton.target = self
        fileImportButton.action = #selector(importWorkspaceFile)
        arcImportStatus.onDismiss = { [weak self] in self?.setImportStatus(self?.arcImportStatus, nil) }
        fileImportStatus.onDismiss = { [weak self] in self?.setImportStatus(self?.fileImportStatus, nil) }
        let importing = SettingsGroupView(section: .importing)
        importing.add(SettingsRow(title: "Arc Browser", control: arcImportButton))
        importing.add(arcImportStatus)
        importing.add(SettingsRow(title: "Workspace file", control: fileImportButton))
        importing.add(fileImportStatus)

        groups = [.workspaces: workspaces, .appearance: appearance, .window: window,
                  .shortcut: shortcut, .browser: browser, .importing: importing]
        for section in Section.allCases {
            if let group = groups[section] { pageView.addSubview(group) }
        }
    }

    private static func glyph(_ name: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        view.imageScaling = .scaleNone
        view.frame = NSRect(x: 0, y: 0, width: 14, height: 12)
        return view
    }

    private static func tintHelpText(_ tint: StowTheme.TintMode) -> String {
        switch tint {
        case .full: return "Each page is filled with its workspace color"
        case .subtle: return "Each page gets a light wash of its color"
        case .off: return "Pages stay neutral; the color shows in the icon"
        }
    }

    // MARK: Layout

    /// Lays out the page (or the rail) for the current width and refreshes the popover size.
    private func relayout() {
        guard isViewLoaded else { return }
        let width = scrollView.contentSize.width
        guard width > 0 else { return }

        if widthMode == .rail {
            layoutRail(width: width)
        } else {
            var y: CGFloat = 0
            var first = true
            for section in Section.allCases {
                guard let group = groups[section], group.superview === pageView else { continue }
                if !first { y += SettingsMetrics.groupGap }
                first = false
                let height = group.height(forWidth: width)
                group.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height
            }
            y += 16
            pageView.frame = NSRect(x: 0, y: 0, width: width, height: y)
        }

        if let popover, let section = popoverSection, let group = groups[section] {
            let popoverWidth: CGFloat = 300
            let inset: CGFloat = 6
            let height = group.height(forWidth: popoverWidth - inset * 2)
            group.frame = NSRect(x: inset, y: 8, width: popoverWidth - inset * 2, height: height)
            popover.contentSize = NSSize(width: popoverWidth, height: height + 16)
        }
        scheduleKeyViewLoop()
    }

    private func scheduleKeyViewLoop() {
        guard !keyViewLoopScheduled else { return }
        keyViewLoopScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyViewLoopScheduled = false
            guard let window = self.view.window, !self.view.isHiddenOrHasHiddenAncestor else { return }
            window.recalculateKeyViewLoop()
        }
    }

    private var workspaceListHeight: CGFloat {
        CGFloat(visibleWorkspaceCount) * SettingsMetrics.rowHeight
    }

    private var visibleWorkspaceCount: Int {
        let count = appModel?.workspaces.count ?? 0
        return showsAllWorkspaces ? count : min(count, Self.visibleWorkspaceLimit)
    }

    // MARK: Width modes

    private func applyWidthMode() {
        popover?.close()
        if widthMode == .rail {
            scrollView.documentView = railView
        } else {
            scrollView.documentView = pageView
        }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func buildRail() {
        for section in Section.allCases {
            let button = SettingsIconButton(symbolName: section.symbolName, accessibilityLabel: section.title, size: 28, pointSize: 13)
            button.translatesAutoresizingMaskIntoConstraints = true
            button.target = self
            button.action = #selector(railButtonClicked(_:))
            button.toolTip = section.title
            railButtons[section] = button
            railView.addSubview(button)
        }
    }

    private func rebuildRailWorkspaceChips() {
        railWorkspaceChips.forEach { $0.removeFromSuperview() }
        railWorkspaceChips = []
        guard let appModel else { return }
        for workspace in appModel.workspaces {
            let chip = RailWorkspaceChip(workspace: workspace, iconLinks: WorkspaceIconSites.pick(from: workspace.items))
            chip.onClick = { [weak self, weak chip] in
                guard let self, let chip else { return }
                self.showWorkspaceMenu(for: workspace.id, anchor: chip)
            }
            railView.addSubview(chip)
            railWorkspaceChips.append(chip)
        }
        if widthMode == .rail { relayout() }
    }

    private func layoutRail(width: CGFloat) {
        var y: CGFloat = 4
        let buttonSize: CGFloat = 28
        let chipSize: CGFloat = 22
        for section in Section.allCases {
            guard let button = railButtons[section] else { continue }
            button.frame = NSRect(x: round((width - buttonSize) / 2), y: y, width: buttonSize, height: buttonSize)
            y += buttonSize + 4
            if section == .workspaces {
                for chip in railWorkspaceChips {
                    chip.frame = NSRect(x: round((width - chipSize) / 2), y: y, width: chipSize, height: chipSize)
                    y += chipSize + 4
                }
                y += 8
            }
        }
        railView.frame = NSRect(x: 0, y: 0, width: width, height: y + 8)
    }

    @objc private func railButtonClicked(_ sender: SettingsIconButton) {
        guard let section = railButtons.first(where: { $0.value === sender })?.key else { return }
        showPopover(for: section, anchor: sender)
    }

    private func showPopover(for section: Section, anchor: NSView) {
        if popoverSection == section, popover?.isShown == true {
            popover?.close()
            return
        }
        popover?.close()
        guard let group = groups[section] else { return }

        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        group.removeFromSuperview()
        container.addSubview(group)
        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        popoverSection = section
        relayout()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    private func returnPopoverGroupToPage() {
        guard let section = popoverSection, let group = groups[section] else { return }
        group.removeFromSuperview()
        pageView.addSubview(group)
        popoverSection = nil
        popover = nil
        relayout()
    }

    // MARK: Workspaces

    private func reloadWorkspaces() {
        guard isViewLoaded, let appModel else { return }

        if renamingWorkspaceId != nil {
            needsReloadAfterRename = true
            return
        }

        let count = appModel.workspaces.count
        let hidden = count - Self.visibleWorkspaceLimit
        if hidden > 0 {
            showMoreRow.isHidden = false
            if showsAllWorkspaces {
                showMoreRow.configure(title: "Show fewer", symbolName: "chevron.up")
            } else {
                showMoreRow.configure(title: "Show \(hidden) more", symbolName: "chevron.down")
            }
        } else {
            showMoreRow.isHidden = true
            showsAllWorkspaces = false
        }
        newWorkspaceRow.isHidden = false

        workspaceCollectionView.reloadData()
        rebuildRailWorkspaceChips()
        pageThumbnails.forEach { $0.colorId = lastViewedWorkspace?.colorId ?? .defaultColor() }
        relayout()

        if let id = pendingRenameId {
            pendingRenameId = nil
            beginInlineRename(id)
        }
    }

    private var lastViewedWorkspace: Workspace? {
        guard let appModel else { return nil }
        if let string = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId),
           let id = UUID(uuidString: string), let workspace = appModel.workspaces.first(id: id) {
            return workspace
        }
        if let id = appModel.state.selectedWorkspaceId, let workspace = appModel.workspaces.first(id: id) {
            return workspace
        }
        return appModel.workspaces.first
    }

    @objc private func toggleShowAllWorkspaces() {
        showsAllWorkspaces.toggle()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StowTheme.Motion.normal
            reloadWorkspaces()
        }
    }

    /// Runs a model change that would select a workspace (create, import) without
    /// leaving Settings or changing which workspace was last viewed.
    private func preservingSelection(_ change: () throws -> Void) rethrows {
        guard let appModel else { return }
        let wasSettings = appModel.state.isSettingsSelected
        let previous = appModel.state.selectedWorkspaceId
        let lastViewed = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        defer {
            if wasSettings {
                if previous == nil { appModel.selectSettings() }
                UserDefaults.standard.set(lastViewed, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            } else if let previous {
                appModel.selectWorkspace(id: previous)
            }
        }
        try change()
    }

    @objc private func createWorkspace() {
        guard let appModel else { return }
        var newId: UUID?
        preservingSelection {
            newId = appModel.createWorkspace(name: "Untitled")
        }
        guard let newId else { return }
        if appModel.workspaces.count > Self.visibleWorkspaceLimit {
            showsAllWorkspaces = true
        }
        pendingRenameId = newId
        reloadWorkspaces()
    }

    private func beginInlineRename(_ id: UUID) {
        guard let appModel, let index = appModel.workspaces.firstIndex(id: id) else { return }
        if widthMode == .rail, popoverSection != .workspaces, let anchor = railButtons[.workspaces] {
            showPopover(for: .workspaces, anchor: anchor)
        }
        if index >= visibleWorkspaceCount {
            showsAllWorkspaces = true
            reloadWorkspaces()
        }
        groups[.workspaces]?.layoutSubtreeIfNeeded()
        workspaceCollectionView.layoutSubtreeIfNeeded()
        let indexPath = IndexPath(item: index, section: 0)
        if let rowFrame = workspaceCollectionView.layoutAttributesForItem(at: indexPath)?.frame {
            workspaceCollectionView.scrollToVisible(rowFrame)
        }
        guard let item = workspaceCollectionView.item(at: indexPath) as? WorkspaceCollectionViewItem else { return }
        renamingWorkspaceId = id
        item.beginInlineRename()
    }

    private func finishInlineRename() {
        renamingWorkspaceId = nil
        if needsReloadAfterRename {
            needsReloadAfterRename = false
            DispatchQueue.main.async { [weak self] in self?.reloadWorkspaces() }
        }
    }

    private func showWorkspaceMenu(for id: UUID, anchor: NSView) {
        guard let appModel else { return }
        let menu = WorkspaceMenu.make(for: id, model: appModel, presentingView: view) { [weak self] id in
            self?.beginInlineRename(id)
        }
        popUp(menu, below: anchor)
    }

    private func popUp(_ menu: NSMenu, below anchor: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 2 : -2), in: anchor)
    }

    private func deleteWorkspace(_ id: UUID) {
        guard let appModel, let window = view.window else { return }
        WorkspaceDeletion.confirm(id, model: appModel, in: window)
    }

    private func profileName(for workspace: Workspace) -> String? {
        guard let bundleId = BrowserManager.resolveDefaultBrowserBundleId(),
              let dir = workspace.browserProfiles[bundleId] else { return nil }
        return BrowserManager.profiles(for: bundleId).first(where: { $0.directoryName == dir })?.displayName ?? dir
    }

    @objc private func scrollBoundsChanged() {
        for item in workspaceCollectionView.visibleItems() {
            (item as? WorkspaceCollectionViewItem)?.refreshHoverState()
        }
    }

    // MARK: Appearance

    private func tintModeChanged(_ index: Int) {
        let modes = StowTheme.TintMode.allCases
        guard modes.indices.contains(index) else { return }
        tintHelp.set(Self.tintHelpText(modes[index]))
        preferences.setTint(modes[index])
    }

    @objc private func tintModeChangedElsewhere() {
        let index = StowTheme.TintMode.allCases.firstIndex(of: StowTheme.preferredTint) ?? 0
        if tintControl.selectedIndex != index {
            tintControl.selectedIndex = index
            tintHelp.set(Self.tintHelpText(StowTheme.preferredTint))
        }
    }

    // MARK: Window

    private var currentWindowMode: AppWindowMode { preferences.windowMode }

    private var hasAccessibility: Bool { preferences.hasAccessibility }

    private func windowModeChanged(_ mode: AppWindowMode) {
        preferences.setWindowMode(mode)
        updateWindowSection()
    }

    private func browserSideChanged(_ index: Int) {
        preferences.setBrowserSide(index)
    }

    private func updateWindowSection() {
        guard isViewLoaded else { return }
        let mode = currentWindowMode
        windowModeControl.selectedIndex = mode.rawValue
        let missingAccess = mode == .attached && !hasAccessibility
        permissionRow.isHidden = !missingAccess
        browserSideRow.isHidden = mode != .attached
        switch mode {
        case .floating:
            windowHelp.set("A regular window you can place anywhere")
        case .onTop:
            windowHelp.set("Stays above every other app")
        case .attached:
            if missingAccess {
                windowHelp.set(nil)
            } else {
                windowHelp.set("Attached beside your browser window", kind: .success)
            }
        }
        relayout()
    }

    @objc private func windowSettingsChangedElsewhere() {
        updateWindowSection()
    }

    @objc private func preferencesChangedElsewhere() {
        tintModeChangedElsewhere()
        browserSideControl.selectedIndex = preferences.browserSide
        if !browsers.isEmpty {
            let index = preferences.selectedBrowserIndex(in: browsers)
            browserPopUp.popup.selectItem(at: index == 0 ? 0 : index + 1)
            browserPopUp.refreshTitle()
        }
        updateWindowSection()
    }

    @objc private func applicationDidBecomeActive() {
        if preferences.applyPendingAttachment() {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Accessibility granted. Stow is attached to your browser.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        updateWindowSection()
    }

    @objc private func openAccessibilitySettings() {
        preferences.openAccessibilitySettings()
    }

    // MARK: Browser

    private func loadBrowsers() {
        let popup = browserPopUp.popup
        browsers = preferences.browserChoices()
        popup.removeAllItems()
        let menu = NSMenu()
        popup.menu = menu
        for (index, choice) in browsers.enumerated() {
            let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
            item.representedObject = index
            if let icon = choice.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            if choice.bundleId == nil { item.toolTip = "Open links in whichever browser you were last using" }
            menu.addItem(item)
            if index == 0 { menu.addItem(.separator()) }
        }
        let selected = preferences.selectedBrowserIndex(in: browsers)
        popup.selectItem(at: selected == 0 ? 0 : selected + 1)
        browserPopUp.refreshTitle()
    }

    @objc private func browserChanged() {
        guard let index = browserPopUp.popup.selectedItem?.representedObject as? Int, browsers.indices.contains(index) else { return }
        browserPopUp.refreshTitle()
        preferences.setBrowser(browsers[index].bundleId)
        // Profiles belong to a browser, so the chips may change.
        reloadWorkspaces()
    }

    // MARK: Import

    /// Reports the outcome of an import started from elsewhere (the rail's app sheet).
    var onImportFinished: ((String, Bool) -> Void)?

    @objc func importFromArc() {
        let arcPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        guard FileManager.default.fileExists(atPath: arcPath.path) else {
            setImportStatus(arcImportStatus, "Couldn't find Arc's data on this Mac", kind: .danger)
            onImportFinished?("Couldn't find Arc's data on this Mac", false)
            return
        }
        Task { @MainActor [weak self] in
            await self?.handleArcImport(fileURL: arcPath)
        }
    }

    private func handleArcImport(fileURL: URL) async {
        arcImportButton.setLoading(true, title: "Importing")
        setImportStatus(arcImportStatus, nil)
        let result = await ArcImportService.shared.importFromArc(fileURL: fileURL)
        arcImportButton.setLoading(false)

        switch result {
        case .success(let importResult):
            applyImport(importResult)
            let count = importResult.workspacesCreated
            let text = "Imported \(count) \(count == 1 ? "workspace" : "workspaces") from Arc"
            setImportStatus(arcImportStatus, text, kind: .success)
            onImportFinished?(text, true)
        case .failure(let error):
            setImportStatus(arcImportStatus, error.localizedDescription, kind: .danger)
            onImportFinished?(error.localizedDescription, false)
        }
    }

    private func applyImport(_ result: ArcImportResult) {
        guard let appModel else { return }
        preservingSelection {
            for workspace in result.workspaces {
                // createWorkspace selects the new workspace, so nodes land in it.
                _ = appModel.createWorkspace(name: workspace.name, colorId: workspace.colorId)
                for node in workspace.nodes {
                    addNodeToWorkspace(node, parentId: nil, appModel: appModel)
                }
            }
        }
        reloadWorkspaces()
    }

    private func addNodeToWorkspace(_ node: Node, parentId: UUID?, appModel: AppModel) {
        switch node {
        case .link(let link):
            appModel.addLink(urlString: link.url, title: link.title, parentId: parentId)
        case .folder(let folder):
            let folderId = appModel.addFolder(name: folder.name, parentId: parentId, isExpanded: false)
            for child in folder.children {
                addNodeToWorkspace(child, parentId: folderId, appModel: appModel)
            }
        case .task(let task):
            appModel.addTask(title: task.title, parentId: parentId)
        case .snippet(let snippet):
            appModel.addSnippet(title: snippet.title, content: snippet.content, language: snippet.language, parentId: parentId)
        }
    }

    @objc func importWorkspaceFile() {
        guard let appModel else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stow") ?? .json]
        panel.allowsMultipleSelection = false
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                var importedId: UUID?
                try self.preservingSelection {
                    importedId = try appModel.importWorkspace(from: data)
                }
                let name = importedId.flatMap { appModel.workspaces.first(id: $0)?.name } ?? url.deletingPathExtension().lastPathComponent
                self.setImportStatus(self.fileImportStatus, "Imported “\(name)”", kind: .success)
                self.onImportFinished?("Imported “\(name)”", true)
            } catch {
                self.setImportStatus(self.fileImportStatus, "Couldn't import: \(error.localizedDescription)", kind: .danger)
                self.onImportFinished?("Couldn't import: \(error.localizedDescription)", false)
            }
            self.reloadWorkspaces()
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// Import status lines stay until dismissed or replaced, and are announced.
    private func setImportStatus(_ line: SettingsStatusLine?, _ text: String?, kind: SettingsStatusLine.Kind = .help) {
        guard let line else { return }
        line.set(text, kind: kind)
        if let text {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        relayout()
    }
}

// MARK: - NSPopoverDelegate

extension SettingsContentViewController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        returnPopoverGroupToPage()
    }
}

// MARK: - NSCollectionViewDataSource

extension SettingsContentViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleWorkspaceCount
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.workspaceItemId, for: indexPath)
        guard let appModel, let workspaceItem = item as? WorkspaceCollectionViewItem,
              appModel.workspaces.indices.contains(indexPath.item) else { return item }

        let workspace = appModel.workspaces[indexPath.item]
        let content = WorkspaceRowView.Content(
            name: workspace.name,
            colorId: workspace.colorId,
            iconLinks: WorkspaceIconSites.pick(from: workspace.items),
            profileName: profileName(for: workspace),
            itemCount: WorkspaceDeletion.itemCount(of: workspace),
            position: indexPath.item + 1,
            total: appModel.workspaces.count,
            canDelete: appModel.workspaces.count > 1
        )
        workspaceItem.configure(workspace: workspace, content: content, actions: .init(
            showMenu: { [weak self] id, anchor in self?.showWorkspaceMenu(for: id, anchor: anchor) },
            showColorMenu: { [weak self] id, anchor in
                guard let self, let appModel = self.appModel else { return }
                self.popUp(WorkspaceMenu.makeColorMenu(for: id, model: appModel, presentingView: self.view), below: anchor)
            },
            showProfileMenu: { [weak self] id, anchor in
                guard let self, let appModel = self.appModel,
                      let menu = WorkspaceMenu.makeProfileMenu(for: id, model: appModel, presentingView: self.view) else { return }
                self.popUp(menu, below: anchor)
            },
            rename: { [weak self] id in self?.beginInlineRename(id) },
            commitRename: { [weak self] id, name in self?.appModel?.renameWorkspace(id: id, newName: name) },
            finishRename: { [weak self] _ in self?.finishInlineRename() },
            delete: { [weak self] id in self?.deleteWorkspace(id) },
            move: { [weak self] id, direction in
                self?.appModel?.moveWorkspace(id: id, direction: direction)
                self?.refocusWorkspace(id)
            }
        ))
        return workspaceItem
    }

    /// Keeps keyboard focus on a workspace row after it moves.
    private func refocusWorkspace(_ id: UUID) {
        reloadWorkspaces()
        guard let appModel, let index = appModel.workspaces.firstIndex(id: id), index < visibleWorkspaceCount else { return }
        workspaceCollectionView.layoutSubtreeIfNeeded()
        if let item = workspaceCollectionView.item(at: IndexPath(item: index, section: 0)) as? WorkspaceCollectionViewItem,
           let row = item.row {
            view.window?.makeFirstResponder(row)
        }
    }
}

// MARK: - NSCollectionViewDelegate

extension SettingsContentViewController: NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renamingWorkspaceId == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let appModel, appModel.workspaces.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        item.setString(appModel.workspaces[indexPath.item].id.uuidString, forType: workspacePasteboardType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        let index = min((proposedDropIndexPath.pointee as IndexPath).item, visibleWorkspaceCount)
        let y = max(0, CGFloat(index) * SettingsMetrics.rowHeight - 1)
        workspaceDropIndicator.showLine(in: CGRect(x: SettingsMetrics.rowPadding, y: y,
                                                   width: collectionView.bounds.width - SettingsMetrics.rowPadding * 2, height: 2))
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        workspaceDropIndicator.hide()
        guard let appModel,
              let string = draggingInfo.draggingPasteboard.pasteboardItems?.first?.string(forType: workspacePasteboardType),
              let id = UUID(uuidString: string),
              let currentIndex = appModel.workspaces.firstIndex(id: id) else { return false }
        var target = indexPath.item
        if currentIndex < target { target -= 1 }
        appModel.reorderWorkspace(id: id, toIndex: target)
        reloadWorkspaces()
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        workspaceDropIndicator.hide()
    }
}

// MARK: - Group view

/// One section of the page: its header and its rows, laid out top to bottom with frames.
/// Hidden items take no space. The same view moves into a popover in rail mode.
final class SettingsGroupView: NSView {
    private struct Item {
        let view: NSView
        let height: (() -> CGFloat)?
    }

    private var items: [Item] = []
    let section: SettingsContentViewController.Section

    init(section: SettingsContentViewController.Section) {
        self.section = section
        super.init(frame: .zero)
        add(SettingsSectionHeader(section.title))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func add(_ view: NSView, height: (() -> CGFloat)? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        items.append(Item(view: view, height: height))
    }

    private func height(of item: Item, width: CGFloat) -> CGFloat {
        if let height = item.height { return height() }
        if let row = item.view as? SettingsRow { return row.height(forWidth: width) }
        if item.view is SettingsSectionHeader { return SettingsMetrics.headerHeight }
        if item.view is SettingsStatusLine { return SettingsMetrics.helpLineHeight }
        return SettingsMetrics.rowHeight
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        items.reduce(0) { $0 + ($1.view.isHidden ? 0 : height(of: $1, width: width)) }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for item in items where !item.view.isHidden {
            let h = height(of: item, width: bounds.width)
            item.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

// MARK: - Rail workspace chip

/// A workspace in the rail: its favicon icon or colored letter chip. Clicking it opens
/// the workspace menu.
private final class RailWorkspaceChip: FocusableControl {
    private let iconView = WorkspaceIconView()
    var onClick: (() -> Void)?

    init(workspace: Workspace, iconLinks: [Link]) {
        super.init(frame: .zero)
        iconView.configure(name: workspace.name, colorId: workspace.colorId, links: iconLinks)
        iconView.onClick = { [weak self] in self?.onClick?() }
        iconView.autoresizingMask = [.width, .height]
        addSubview(iconView)
        layer?.cornerRadius = SettingsMetrics.rowRadius
        toolTip = workspace.name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(workspace.name), workspace menu")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        iconView.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    override func performAction() { onClick?() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHovered ? SettingsColors.fill : NSColor.clear).cgColor
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 0
        layer?.borderColor = SettingsColors.accent.cgColor
    }

    override func handleHoverStateChanged() { needsDisplay = true }
}

// MARK: - Collection view

/// The workspace list. The rows take keyboard focus themselves, so the list doesn't.
private final class WorkspaceListCollectionView: NSCollectionView {
    override var canBecomeKeyView: Bool { false }
}

// MARK: - Flipped view

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Workspace drop indicator

private final class WorkspaceDropIndicatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 1
        layer?.backgroundColor = SettingsColors.accent.cgColor
    }

    func showLine(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }
}

extension Notification.Name {
    static let stowTintModeChanged = Notification.Name("StowTintModeChanged")
}
