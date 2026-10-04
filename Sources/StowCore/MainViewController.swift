import AppKit
import Combine
import ObjectiveC


@MainActor
final class MainViewController: NSViewController {
    let model: AppModel

    // Coordinators and child view controllers
    private let searchCoordinator = SearchCoordinator()
    private let nodeListViewController = NodeListViewController()
    private let settingsViewController = SettingsContentViewController()

    // UI Components
    private let workspaceSwitcher = WorkspaceStripView()
    private let titleSettingsButton = NSButton()
    private let railView = RailView()
    /// Rename, Edit URL, due date and snippet flyouts, for the list, the mosaic and the rail.
    let itemFlyouts = ItemFlyouts()
    /// The one snippet editor, moved between snippets.
    private lazy var snippetEditor = SnippetEditorView()
    /// Settings in rail mode: workspace tiles, their editor and the app sheet.
    private lazy var settingsRail = SettingsRailController(model: model)
    /// The workspace editor for the Settings page, rail dots, title-bar tabs and the
    /// Tabline chip (the Settings rail shows its own in its flyout stack).
    private(set) lazy var workspaceEditor = WorkspaceEditorController(model: model)
    /// What the rail showed last, to grow dots into tiles (and back) when it changes.
    private enum RailPage { case none, workspace, settings }
    private var railPage: RailPage = .none
    private var isRailMorphing = false
    /// The workspace on screen before Settings, for the 4pt dot and the way back.
    private var lastShownWorkspaceId: UUID?
    /// Released in rail so the hidden list's minimum width can't hold the window wider than the rail.
    private var contentStackTrailing: NSLayoutConstraint!
    /// The page content was hidden because the rail took over; leaving the rail shows it again.
    private var contentHiddenByRail = false
    private var elasticMode: ElasticMode = .sidebar
    /// The first layout applies the width's mode even when it matches the default.
    private var hasAppliedElasticMode = false
    /// The Settings page's own width (~240pt) would stop the window narrowing to a rail,
    /// so its constraints are switched off whenever Settings isn't showing.
    private var settingsConstraints: [NSLayoutConstraint] {
        view.constraints.filter { ($0.firstItem as? NSView) === settingsViewController.view || ($0.secondItem as? NSView) === settingsViewController.view }
    }
    private let titleAddButton = NSButton()
    private let searchField = SearchBarView(style: .defaultSearch)
    private let stowTabButton = FooterButton(title: "+ Stow this tab", keycap: "⌥⌘S", symbolName: "plus")
    private let pasteButton = FooterButton(title: "Paste", symbolName: "doc.on.clipboard")
    /// Open browser tabs, for the rail's and the list's open dots.
    private let openTabs = OpenTabsMonitor.shared
    private var openTabsSubscription: AnyCancellable?
    private var modelSubscription: AnyCancellable?

    // Page navigation
    private let pageController = ScrollWheelPageController()
    private var topBar = NSView()

    // Content containers (show/hide for page switching)
    private let contentStack = NSStackView()

    // Swipe state
    private var isSwiping = false
    /// A reload asked for mid-swipe, run once the swipe ends.
    private var needsReloadAfterSwipe = false
    private var lastAddNewHapticTime: TimeInterval = 0
    private var outgoingSnapshotView: NSImageView?
    private var swipeStartPageIndex: Int = 0
    private var preloadedPageIndex: Int?
    private var swipeDirection: Int = 0 // -1 backward, 0 none, +1 forward
    /// The rail's items as they were when a rail swipe began, sliding out with the finger.
    private var railOutgoingSnapshot: NSImageView?
    private var isRailSwipe: Bool { elasticMode == .rail && !railView.isHidden }

    // Key event monitor
    nonisolated(unsafe) private var keyEventMonitor: Any?
    nonisolated(unsafe) private var flagsMonitor: Any?
    /// Pending reveal of jump letters while ⌘ is held on its own.
    private var commandHoldReveal: DispatchWorkItem?
    /// True while the letters are showing because ⌘ is held (as opposed to ⌘J mode).
    private var isCommandHoldJump = false

    // State
    private var isReloadScheduled = false
    private var hasLoaded = false
    private var lastWorkspaceId: UUID?
    private var pendingWorkspaceRenameId: UUID?
    private var displayedColorId: WorkspaceColorId = .defaultColor()
    private var appearanceObservation: NSKeyValueObservation?
    private var hasClaimedInitialFocus = false
    private var lastEmptyStateKind: EmptyStateKind = .none
    private var lastEmptyStateWorkspaceId: UUID?
    private var revealArchivedMatches = false
    private var noMatchesAnnouncement: DispatchWorkItem?

    /// Set once any item has ever been added, so first-launch onboarding never returns.
    private var hasAddedFirstItem: Bool {
        get { UserDefaults.standard.bool(forKey: "StowHasAddedFirstItem") }
        set { UserDefaults.standard.set(newValue, forKey: "StowHasAddedFirstItem") }
    }

    private static let arcSidebarURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    private static let hasArcData = FileManager.default.fileExists(atPath: arcSidebarURL.path)

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let view = FileDropView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChildViewControllers()
        setupUI()
        setupSearchCoordinator()
        setupNodeListCallbacks()
        bindModel()
        reloadData()
        observeAppearanceChanges()
        let tabline = TablineController.shared
        tabline.bind(model: model)
        tabline.onOpenLink = { [weak self] link in self?.openLink(link) }
        tabline.onSelectWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        // The Tabline shows the active workspace, so that's where its ghost tab is stowed.
        tabline.onStowURL = { [weak self] url, title in
            guard let self else { return nil }
            return self.stow(url: url, title: title, into: tabline.content.workspaceId)
        }
        // Task ids are found in whichever workspace holds them.
        tabline.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        tabline.onWorkspaceContextMenu = { [weak self] id, view, rect in
            self?.showWorkspaceMenu(for: id, in: view, at: NSPoint(x: rect.minX, y: view.isFlipped ? rect.maxY + 2 : rect.minY - 2),
                                    editorAnchor: rect, edge: .below)
        }
        tabline.startIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(tintModeChanged), name: .stowTintModeChanged, object: nil)
        nodeListViewController.tintMode = StowTheme.displayTint

        // FaviconPrefetcher's results are written into the library here.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdate),
            name: .stowLinkFaviconFetched,
            object: nil
        )

        // Plain a-z key monitor for item activation
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleCommandHoldKey(event) { return nil }
            if self.handlePlainKeyEvent(event) { return nil }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let window = view.window {
            pageController.attach(to: window)
        }
        updatePageWidth()
        pageController.jumpToPage(currentPageIndex())
        updateOpenTabsPolling()
        // Start with the list focused, not the search field. AppKit picks the first key
        // view when the window first becomes key, so take focus back once that happens.
        if let window = view.window, !hasClaimedInitialFocus {
            hasClaimedInitialFocus = true
            window.initialFirstResponder = nodeListViewController.focusTarget
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidFirstBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionChanged(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePageWidth()
        applyElasticMode(ElasticMode.forWidth(view.bounds.width))
        updateFooterFit()
    }

    // MARK: - Setup

    private func setupChildViewControllers() {
        addChild(nodeListViewController)
        addChild(settingsViewController)
    }

    private func setupUI() {
        // Workspace switcher
        workspaceSwitcher.translatesAutoresizingMaskIntoConstraints = false
        workspaceSwitcher.onWorkspaceSelected = { [weak self] workspaceId in
            guard let self else { return }
            self.model.selectWorkspace(id: workspaceId)
            if let idx = self.model.workspaces.firstIndex(where: { $0.id == workspaceId }) {
                self.pageController.jumpToPage(idx + 1)
            }
        }
        nodeListViewController.onOpenLinkIn = { [weak self] link, choice in
            self?.openLink(link, in: choice)
        }
        workspaceSwitcher.onWorkspaceRightClick = { [weak self] workspaceId, point in
            guard let self else { return }
            let local = self.view.convert(point, from: nil)
            self.showWorkspaceMenu(for: workspaceId, in: self.view, at: local,
                                   editorAnchor: NSRect(x: local.x, y: local.y, width: 1, height: 1), edge: .below)
        }
        workspaceSwitcher.onWorkspaceReorder = { [weak self] workspaceId, index in
            self?.model.reorderWorkspace(id: workspaceId, toIndex: index)
        }
        for (button, symbol, label, action) in [
            (titleSettingsButton, "gearshape", "Settings", #selector(titleSettingsTapped)),
            (titleAddButton, "plus", "New", #selector(showNewItemMenu)),
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
        }
        titleSettingsButton.toolTip = "Settings (⌘,)"
        titleAddButton.toolTip = "New folder, task, snippet or workspace"
        titleAddButton.setAccessibilityLabel("New")
        workspaceSwitcher.onDropNode = { [weak self] nodeId, workspaceId in
            self?.model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
        }

        workspaceSwitcher.onWorkspaceRename = { [weak self] workspaceId, newName in
            self?.model.renameWorkspace(id: workspaceId, newName: newName)
        }


        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search"
        searchField.onMoveDown = { [weak self] in
            self?.nodeListViewController.focusList()
        }
        searchField.onTextChange = { [weak self] text in
            self?.revealArchivedMatches = false
            self?.nodeListViewController.clearSelections()
            self?.searchCoordinator.updateQuery(text)
        }

        // Paste button
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.target = self
        pasteButton.action = #selector(importClipboardContent)
        pasteButton.toolTip = "Paste links, tasks or text from the clipboard (⌘V)"

        stowTabButton.translatesAutoresizingMaskIntoConstraints = false
        stowTabButton.target = self
        stowTabButton.action = #selector(stowTabTapped)
        updateStowTabShortcut()
        NotificationCenter.default.addObserver(self, selector: #selector(updateStowTabShortcut), name: .toggleSidebarShortcutChanged, object: nil)

        // Node list view
        nodeListViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Settings view
        settingsViewController.workspaceEditor = workspaceEditor
        settingsViewController.onOpenWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        settingsViewController.appModel = model
        settingsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        settingsViewController.view.isHidden = true

        // Build content stack (search + nodeList + paste)
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(stowTabButton)
        bottomBar.addSubview(pasteButton)
        self.bottomBar = bottomBar

        contentStack.orientation = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.alignment = .centerX
        contentStack.addArrangedSubview(searchField)
        contentStack.addArrangedSubview(nodeListViewController.view)
        contentStack.addArrangedSubview(bottomBar)
        // Search, then 10pt to the list, then 6pt to the footer, as in the mockup.
        contentStack.setCustomSpacing(10, after: searchField)

        // Top bar layout
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(workspaceSwitcher)

        // Main layout: top bar + content area
        view.addSubview(topBar)
        view.addSubview(titleSettingsButton)
        view.addSubview(titleAddButton)
        view.addSubview(contentStack)
        view.addSubview(settingsViewController.view)
        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.isHidden = true
        view.addSubview(railView)
        let settingsRailView = settingsRail.view
        settingsRailView.translatesAutoresizingMaskIntoConstraints = false
        settingsRailView.isHidden = true
        view.addSubview(settingsRailView)
        wireRail()

        let pad = LayoutConstants.windowPadding
        contentStackTrailing = contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad)
        // Just below required: whatever minimum width the list or header has, dragging the
        // window narrower must still reach the rail, which only then swaps them out.
        contentStackTrailing.priority = .init(999)
        let topBarTrailing = topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad)
        topBarTrailing.priority = .init(999)

        NSLayoutConstraint.activate([
            stowTabButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            stowTabButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            pasteButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            pasteButton.leadingAnchor.constraint(greaterThanOrEqualTo: stowTabButton.trailingAnchor, constant: 4),

            bottomBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            searchField.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            // Rows sit 6pt from the panel edge, 2pt outside the search field.
            nodeListViewController.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: 4),

            bottomBar.heightAnchor.constraint(equalToConstant: 30),

            workspaceSwitcher.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            workspaceSwitcher.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            workspaceSwitcher.topAnchor.constraint(equalTo: topBar.topAnchor),
            workspaceSwitcher.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            topBarTrailing,
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            topBar.heightAnchor.constraint(equalToConstant: 28),

            // Settings and New Workspace sit in the traffic-light row, in page order.
            titleAddButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            titleAddButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            titleAddButton.widthAnchor.constraint(equalToConstant: 24),
            titleAddButton.heightAnchor.constraint(equalToConstant: 22),
            titleSettingsButton.trailingAnchor.constraint(equalTo: titleAddButton.leadingAnchor, constant: -2),
            titleSettingsButton.centerYAnchor.constraint(equalTo: titleAddButton.centerYAnchor),
            titleSettingsButton.widthAnchor.constraint(equalToConstant: 24),
            titleSettingsButton.heightAnchor.constraint(equalToConstant: 22),

            // Content stack fills area below topBar
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            contentStackTrailing,
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),

            // Settings view pinned to same content area
            settingsViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            settingsViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            settingsViewController.view.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            settingsViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),

            railView.topAnchor.constraint(equalTo: view.topAnchor),
            railView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            railView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            settingsRailView.topAnchor.constraint(equalTo: view.topAnchor),
            settingsRailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            settingsRailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            settingsRailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        wireEmptyState()

        // Setup page controller
        pageController.delegate = self
        pageController.excludedView = workspaceSwitcher
    }

    private func setupSearchCoordinator() {
        searchCoordinator.onQueryChanged = { [weak self] _ in
            self?.reloadData()
        }
    }

    private func setupNodeListCallbacks() {
        nodeListViewController.nodeProvider = { [weak self] in
            guard let self else { return [] }
            return self.searchCoordinator.filter(nodes: self.model.currentWorkspace.items)
        }

        nodeListViewController.workspacesProvider = { [weak self] in
            self?.model.workspaces ?? []
        }

        nodeListViewController.currentWorkspaceIdProvider = { [weak self] in
            self?.model.currentWorkspace.id
        }

        nodeListViewController.findNodeById = { [weak self] id in
            self?.model.nodeById(id)
        }

        nodeListViewController.findNodeLocation = { [weak self] id in
            self?.model.location(of: id)
        }

        nodeListViewController.findNodeInNodes = { [weak self] id, nodes in
            self?.model.findNode(id: id, in: nodes)
        }

        nodeListViewController.onNodeSelected = { [weak self] nodeId in
            guard let self, let node = self.model.nodeById(nodeId) else { return }
            switch node {
            case .link(let link):
                self.openLink(link)
            case .snippet:
                self.copySnippetToClipboard(nodeId)
            default:
                break
            }
        }

        nodeListViewController.onFolderToggled = { [weak self] folderId, _ in
            guard let self else { return }
            if self.searchCoordinator.isSearchActive { return }
            if let node = self.model.nodeById(folderId), case .folder(let folder) = node {
                self.model.setFolderExpanded(id: folder.id, isExpanded: !folder.isExpanded)
            }
        }

        nodeListViewController.onNodeMoved = { [weak self] nodeId, targetParentId, targetIndex in
            self?.model.moveNode(id: nodeId, toParentId: targetParentId, index: targetIndex)
        }

        nodeListViewController.onNodeDeleted = { [weak self] nodeId in
            self?.archiveUndoably([nodeId])
        }

        nodeListViewController.onNodeUnarchived = { [weak self] nodeId in
            self?.model.unarchiveNode(id: nodeId)
        }

        nodeListViewController.onNodePermanentlyDeleted = { [weak self] nodeId in
            guard let self else { return }
            PendingChange.deletePermanently(nodeId, model: self.model)?.offer(in: self.view.window)
        }

        nodeListViewController.onArchiveToggled = { [weak self] isExpanded in
            guard let self else { return }
            self.model.setArchiveExpanded(workspaceId: self.model.currentWorkspace.id, isExpanded: isExpanded)
        }

        nodeListViewController.onNodeRenamed = { [weak self] nodeId, newName in
            self?.model.renameNode(id: nodeId, newName: newName)
        }

        nodeListViewController.onNodeMovedToWorkspace = { [weak self] nodeId, workspaceId in
            self?.model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesMovedToWorkspace = { [weak self] nodeIds, workspaceId in
            self?.model.moveNodesToWorkspace(nodeIds: nodeIds, toWorkspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesGrouped = { [weak self] nodeIds, folderName in
            self?.model.groupNodesInNewFolder(nodeIds: nodeIds, folderName: folderName)
        }

        nodeListViewController.onBulkNodesCopied = { [weak self] nodeIds in
            self?.handleBulkCopyLinks(nodeIds)
        }

        nodeListViewController.onBulkNodesDeleted = { [weak self] nodeIds in
            self?.archiveUndoably(nodeIds)
        }

        nodeListViewController.onLinkUrlEdited = { [weak self] nodeId, newUrl in
            guard let self else { return }
            self.model.updateLinkUrl(id: nodeId, newUrl: newUrl)
            // Fetch new title and favicon for the updated URL
            if let url = URL(string: newUrl) {
                self.fetchTitleForNewLink(id: nodeId, url: url)
            }
        }

        nodeListViewController.onOpenFolderLinks = { [weak self] folderId in
            guard let self, let node = self.model.nodeById(folderId), case .folder(let folder) = node else { return }
            self.openLinksInFolder(folder)
        }

        nodeListViewController.onBulkOpenLinks = { [weak self] nodeIds in
            guard let self else { return }
            for nodeId in nodeIds {
                if let node = self.model.findNode(id: nodeId, in: self.model.currentWorkspace.items),
                   case .link(let link) = node {
                    self.openLink(link)
                }
            }
        }

        nodeListViewController.onNewFolderRequested = { [weak self] parentId in
            self?.createFolderAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onTaskToggled = { [weak self] taskId in
            self?.model.toggleTaskCompletion(id: taskId)
        }

        nodeListViewController.onSnippetClicked = { [weak self] snippetId in
            self?.copySnippetToClipboard(snippetId)
        }

        nodeListViewController.onTaskDueDateRequested = { [weak self] taskId in
            self?.showDatePickerForTask(taskId)
        }

        nodeListViewController.onTaskDueDateCleared = { [weak self] taskId in
            self?.model.updateTaskDueDate(id: taskId, dueDate: nil)
        }

        nodeListViewController.onSnippetEditRequested = { [weak self] snippetId in
            self?.showSnippetEditor(snippetId)
        }

        nodeListViewController.onNewTaskRequested = { [weak self] parentId in
            self?.createTaskAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onNewWorkspaceRequested = { [weak self] in
            self?.promptCreateWorkspace()
        }

        nodeListViewController.onNewSnippetRequested = { [weak self] parentId in
            self?.createSnippetAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onMoveToNewWorkspace = { [weak self] nodeIds in
            self?.moveToNewWorkspace(nodeIds)
        }

        nodeListViewController.onMoveToNewFolder = { [weak self] nodeIds in
            self?.moveToNewFolder(nodeIds)
        }

        nodeListViewController.onDropText = { [weak self] text, parentId, index in
            self?.addDroppedText(text, parentId: parentId, index: index)
        }

        nodeListViewController.flyouts = itemFlyouts
        nodeListViewController.nodeMenuProvider = { [weak self] node in
            self?.nodeMenu(for: node)
        }
    }

    // MARK: - Item menu

    /// The NodeMenu for an item in whatever the window shows: the list and mosaic edit
    /// beside the row or tile, the rail beside its cell.
    func nodeMenu(for node: Node) -> NSMenu? {
        var actions = NodeMenu.Actions()
        actions.rename = { [weak self] id in self?.beginRename(id) }
        actions.editURL = { [weak self] id in
            guard let self else { return }
            self.nodeListViewController.presentEditURLFlyout(for: id, from: self.railAnchor(for: id))
        }
        actions.setDueDate = { [weak self] id in self?.showDatePickerForTask(id) }
        actions.editSnippet = { [weak self] id in self?.showSnippetEditor(id) }
        actions.copySnippet = { [weak self] id in self?.copySnippetToClipboard(id) }
        actions.openIn = { [weak self] link, choice in self?.openLink(link, in: choice) }
        actions.openFolder = { [weak self] folder in self?.openLinksInFolder(folder) }
        actions.newFolderInside = { [weak self] id in self?.createFolderAndBeginRename(parentId: id) }
        actions.moveToNewWorkspace = { [weak self] ids in self?.moveToNewWorkspace(ids) }
        actions.moveToNewFolder = { [weak self] ids in self?.moveToNewFolder(ids) }
        actions.archive = { [weak self] id in self?.archiveUndoably([id]) }
        return NodeMenu.make(for: node, model: model, actions: actions)
    }

    /// In the rail, the cell an editor flyout points at (the whole rail for items it
    /// shows inside a group cell); nil elsewhere, where the list finds the row.
    private func railAnchor(for nodeId: UUID?) -> NSView? {
        guard elasticMode == .rail else { return nil }
        return nodeId.flatMap { railView.cellView(for: $0) } ?? railView
    }

    private func anchorView(for nodeId: UUID) -> NSView? {
        railAnchor(for: nodeId) ?? nodeListViewController.rowAnchorView(for: nodeId)
    }

    private func beginRename(_ nodeId: UUID) {
        if let anchor = railAnchor(for: nodeId) {
            nodeListViewController.presentRenameFlyout(for: nodeId, from: anchor)
        } else {
            nodeListViewController.beginRename(for: nodeId)
        }
    }

    private func moveToNewWorkspace(_ nodeIds: [UUID]) {
        guard !nodeIds.isEmpty else { return }
        if elasticMode == .rail { return createWorkspaceInRail(moving: nodeIds) }
        let workspaceId = model.createWorkspace(name: "Untitled")
        for nodeId in nodeIds {
            model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
        }
        if let idx = model.workspaces.firstIndex(where: { $0.id == workspaceId }) {
            pageController.jumpToPage(idx + 1)
        }
        scheduleWorkspaceInlineRename(for: workspaceId)
    }

    private func moveToNewFolder(_ nodeIds: [UUID]) {
        guard !nodeIds.isEmpty else { return }
        if elasticMode == .rail { return createFolderInRail(parentId: nil, moving: nodeIds) }
        let folderId = model.addFolder(name: NodeDefaults.folderName, parentId: nil)
        for nodeId in nodeIds {
            model.moveNode(id: nodeId, toParentId: folderId, index: 0)
        }
        nodeListViewController.scheduleInlineRename(for: folderId)
    }

    private func bindModel() {
        modelSubscription = model.changeOrigins.sink { [weak self] origin in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only local edits go up to iCloud; a fetch arriving isn't echoed back.
                if origin == .local { CloudSyncManager.shared.scheduleLocalChanges() }
                if self.isReloadScheduled { return }
                self.isReloadScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isReloadScheduled = false
                    self.reloadData()
                }
            }
        }
        openTabsSubscription = openTabs.$openKeys.removeDuplicates().sink { [weak self] keys in
            MainActor.assumeIsolated {
                self?.railView.setOpenKeys(keys)
                self?.nodeListViewController.openKeys = keys
            }
        }
    }

    // MARK: - Data Reload

    /// `animated: false` swaps the list without a diff, for content a swipe preview replaced.
    private func reloadData(animated: Bool = true) {
        if isSwiping {
            needsReloadAfterSwipe = true
            return
        }
        needsReloadAfterSwipe = false

        // Cancel any in-progress inline rename if node is deleted
        if let renameId = nodeListViewController.inlineRenameNodeId,
           model.nodeById(renameId) == nil {
            nodeListViewController.cancelInlineRename()
        }

        let isNodeRenaming = nodeListViewController.inlineRenameNodeId != nil
        let isWorkspaceRenaming = workspaceSwitcher.isInlineRenaming

        // Skip workspace menu rebuild if mid-rename to preserve text field focus
        if !isWorkspaceRenaming {
            reloadWorkspaceMenu()
        }

        // Notify settings view that workspaces may have changed
        settingsViewController.notifyWorkspacesChanged()

        // Clear selections when workspace changes
        let currentWorkspaceId = model.currentWorkspace.id
        if hasLoaded && currentWorkspaceId != lastWorkspaceId {
            nodeListViewController.clearSelections()
            lastWorkspaceId = currentWorkspaceId
        }

        // Update page width
        updatePageWidth()

        // Show/hide content based on settings selection
        if model.state.isSettingsSelected {
            nodeListViewController.clearSelections()
            showSettingsContent()
            applyBackgroundColor(for: .settingsBackground)
            if elasticMode == .rail { settingsRail.reload() }
        } else {
            lastShownWorkspaceId = currentWorkspaceId
            showWorkspaceContent()
            applyBackgroundColor(for: model.currentWorkspace.colorId)
            DockIconRenderer.apply(model.currentWorkspace.colorId)
            nodeListViewController.workspaceColor = model.currentWorkspace.colorId
            let workspace = model.currentWorkspace
            let forceExpand = searchCoordinator.isSearchActive
            nodeListViewController.isSearchActive = searchCoordinator.isSearchActive

            // Partition items into active and archived, at every depth
            let activeItems = workspace.items.unarchived()
            let archivedItems = workspace.items.archivedLeaves()
            let filteredNodes = searchCoordinator.filter(nodes: activeItems)
            let isSearching = searchCoordinator.isSearchActive
            let archivedMatches = isSearching ? searchCoordinator.filter(nodes: archivedItems, includeArchived: true) : []
            let activeCount = workspace.items.activeItemCount()
            let archivedMatchCount = archivedMatches.leafCount()
            var summary = "\(filteredNodes.leafCount()) of \(activeCount)"
            if archivedMatchCount > 0 { summary += " · \(archivedMatchCount) archived" }
            searchField.resultSummary = isSearching ? summary : nil

            if model.workspaces.contains(where: { !$0.items.isEmpty }) && !hasAddedFirstItem {
                hasAddedFirstItem = true
            }
            // The archive closes itself once the last item is put back or deleted.
            if archivedItems.isEmpty && workspace.isArchiveExpanded {
                model.setArchiveExpanded(workspaceId: workspace.id, isExpanded: false)
            }

            var kind = EmptyStateKind.resolve(
                activeCount: activeItems.count,
                archivedCount: archivedItems.leafCount(),
                query: isSearching ? searchField.text : "",
                matchedCount: filteredNodes.count,
                archivedMatchedCount: archivedMatchCount,
                isArchiveExpanded: workspace.isArchiveExpanded,
                isFirstLaunch: !hasAddedFirstItem && model.workspaces.count == 1,
                hasArcData: Self.hasArcData
            )
            let showArchivedMatches = isSearching && revealArchivedMatches && archivedMatchCount > 0
            if showArchivedMatches { kind = .none }

            let sameWorkspace = workspace.id == lastEmptyStateWorkspaceId
            let wasWelcoming = lastEmptyStateKind == .emptyWorkspace || lastEmptyStateKind.isFirstLaunch
            if kind == .none && wasWelcoming && sameWorkspace && !activeItems.isEmpty {
                nodeListViewController.dismissEmptyStateWithLanding()
            } else {
                nodeListViewController.showEmptyState(
                    EmptyStateCopy.make(kind, workspaceName: workspace.name, isTouch: false),
                    workspaceName: workspace.name,
                    animated: hasLoaded && sameWorkspace
                )
            }
            if case .noMatches = kind, kind != lastEmptyStateKind { announceNoMatches() }
            lastEmptyStateKind = kind
            reloadRail()
            lastEmptyStateWorkspaceId = workspace.id
            refreshPasteAvailability()

            // Skip node list rebuild if mid-rename to preserve text field focus
            if !isNodeRenaming {
                let archiveRows: [Node]
                if case .allArchived = kind { archiveRows = [] } else { archiveRows = showArchivedMatches ? archivedMatches : archivedItems }
                nodeListViewController.reloadData(
                    with: filteredNodes,
                    forceExpand: forceExpand,
                    animated: animated,
                    archivedNodes: archiveRows,
                    isArchiveExpanded: showArchivedMatches || workspace.isArchiveExpanded,
                    showArchiveDuringSearch: showArchivedMatches
                )
            }
        }

        hasLoaded = true
    }

    private func reloadWorkspaceMenu() {
        let workspaces = model.workspaces

        workspaceSwitcher.workspaces = workspaces.map { workspace in
            WorkspaceStripView.WorkspaceItem(
                id: workspace.id,
                name: workspace.name,
                colorId: workspace.colorId
            )
        }

        workspaceSwitcher.isSettingsSelected = model.state.isSettingsSelected

        if model.state.isSettingsSelected {
            workspaceSwitcher.selectedWorkspaceId = nil
            workspaceSwitcher.workspaceColor = .settingsBackground
        } else {
            let selectedId = model.currentWorkspace.id
            workspaceSwitcher.selectedWorkspaceId = selectedId
            workspaceSwitcher.workspaceColor = model.currentWorkspace.colorId
        }

        handlePendingWorkspaceRename()
    }

    private func applyBackgroundColor(for colorId: WorkspaceColorId) {
        let bgColor = colorId.adaptiveBackgroundColor
        view.layer?.backgroundColor = view.resolvedCGColor(bgColor)
        view.window?.backgroundColor = bgColor
        displayedColorId = colorId
        let colors = StowTheme.colors(for: colorId, tint: StowTheme.displayTint)
        searchField.colors = colors
        updateTitleButtons(colors: colors)
        updateSettingsConstraints()
        pasteButton.colors = colors
        stowTabButton.colors = colors
    }

    private func observeAppearanceChanges() {
        appearanceObservation = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyBackgroundColor(for: self.displayedColorId)
                self.nodeListViewController.updateShadows()
            }
        }
    }

    // MARK: - Page Navigation

    /// Returns the total number of pages: settings + workspaces + add-new.
    private func totalPageCount() -> Int {
        model.workspaces.count + 2
    }

    /// Returns the current page index based on model state.
    private func currentPageIndex() -> Int {
        if model.state.isSettingsSelected { return 0 }
        if let idx = model.workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) {
            return idx + 1
        }
        return 1
    }

    /// Returns the color for a page index.
    private func colorForPage(_ pageIndex: Int) -> WorkspaceColorId {
        if pageIndex == 0 { return .settingsBackground }
        let workspaceIdx = pageIndex - 1
        if workspaceIdx < model.workspaces.count {
            return model.workspaces[workspaceIdx].colorId
        }
        if let last = model.workspaces.last {
            return last.colorId
        }
        return .settingsBackground
    }

    /// Width of the content area (used as page width for swipe calculations).
    private var contentAreaWidth: CGFloat {
        view.bounds.width - 2 * LayoutConstants.windowPadding
    }

    /// Syncs the page controller's page width with the current content area width.
    private func updatePageWidth() {
        let width = contentAreaWidth
        if width > 0 {
            pageController.pageWidth = SettingsRailNavigation.swipePageWidth(contentWidth: width, isRail: elasticMode == .rail)
            pageController.maxPagesPerSwipe = elasticMode == .rail ? 1 : nil
        }
    }

    // MARK: - Content Show/Hide

    private func showSettingsContent() {
        contentStack.isHidden = true
        // In rail mode Settings is the rail of workspace tiles, not the page.
        settingsViewController.view.isHidden = elasticMode == .rail
        updateRailVisibility()
    }

    private func showWorkspaceContent() {
        if !settingsViewController.view.isHidden { settingsViewController.closeFlyouts() }
        settingsViewController.view.isHidden = true
        contentStack.isHidden = false
        updateRailVisibility()
    }

    // MARK: - Workspace Management

    /// Where the workspace editor goes relative to what opened it.
    private enum WorkspaceEditorEdge { case below, besideWindow }

    /// The native WorkspaceMenu at `point` in `view`, for a right-click on a title-bar tab,
    /// a rail dot or the Tabline chip. Its Edit… opens the workspace editor at
    /// `editorAnchor` (in `view`).
    private func showWorkspaceMenu(for workspaceId: UUID, in view: NSView, at point: NSPoint,
                                   editorAnchor: NSRect, edge: WorkspaceEditorEdge) {
        guard view.window != nil else { return }
        let menu = WorkspaceMenu.make(for: workspaceId, model: model, presentingView: view) { [weak self, weak view] id in
            guard let self, let view else { return }
            self.openWorkspaceEditor(id, from: view, rect: editorAnchor, edge: edge)
        }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func openWorkspaceEditor(_ id: UUID, from view: NSView, rect: NSRect, edge: WorkspaceEditorEdge) {
        workspaceEditor.onOpenWorkspace = { [weak self] id in
            self?.workspaceEditor.close()
            self?.selectWorkspaceAndPage(id)
        }
        workspaceEditor.open(id, placement: { [weak view] in
            guard let view, let window = view.window else { return nil }
            let anchor = window.convertToScreen(view.convert(rect, to: nil))
            switch edge {
            case .below: return .init(anchor: anchor, edge: .below, topInset: 0, parent: window)
            case .besideWindow: return .init(anchor: anchor, edge: .beside(column: window.frame), topInset: 28, parent: window)
            }
        }, focusName: true)
    }

    /// ⌘N, the + menus and the add-new page. In the rail the strip is hidden, so the new
    /// workspace is named in the Settings rail's editor instead.
    func promptCreateWorkspace() {
        if elasticMode == .rail { return createWorkspaceInRail() }
        let workspaceId = model.createWorkspace(name: "Untitled")
        if let idx = model.workspaces.firstIndex(where: { $0.id == workspaceId }) {
            pageController.jumpToPage(idx + 1)
        }
        scheduleWorkspaceInlineRename(for: workspaceId)
    }

    private func scheduleWorkspaceInlineRename(for workspaceId: UUID) {
        pendingWorkspaceRenameId = workspaceId
    }

    private func handlePendingWorkspaceRename() {
        guard let workspaceId = pendingWorkspaceRenameId else { return }
        pendingWorkspaceRenameId = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.workspaceSwitcher.beginInlineRename(workspaceId: workspaceId)
        }
    }

    // MARK: - Node Management

    /// Archives the items with an undo (⌘Z and the toast).
    private func archiveUndoably(_ ids: [UUID]) {
        PendingChange.archive(ids, model: model)?.offer(in: view.window)
    }

    func createTaskAndBeginRename(parentId: UUID?) {
        if elasticMode == .rail { return createTaskInRail(parentId: parentId) }
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addTask(title: "Untitled", parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    func createSnippetAndBeginRename(parentId: UUID?) {
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        if elasticMode == .rail {
            let newId = model.addSnippet(title: "Untitled", content: "", language: nil, parentId: parentId)
            return showSnippetEditor(newId, discardOnCancel: true)
        }
        let newId = model.addSnippet(title: "Untitled", content: "", language: nil, parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    func createFolderAndBeginRename(parentId: UUID?) {
        if elasticMode == .rail { return createFolderInRail(parentId: parentId) }
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addFolder(name: NodeDefaults.folderName, parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    // MARK: - Creating in the rail

    /// Settings, then the new workspace's editor with its name focused.
    private func createWorkspaceInRail(moving nodeIds: [UUID] = []) {
        enterSettings()
        reloadData(animated: false)
        view.layoutSubtreeIfNeeded()
        settingsRail.createWorkspace(moving: nodeIds)
    }

    /// Adds the folder, then names it in a flyout beside its cell. Cancelling takes an
    /// empty new folder away again; one that was given items keeps the default name.
    private func createFolderInRail(parentId: UUID?, moving nodeIds: [UUID] = []) {
        if let parentId { model.setFolderExpanded(id: parentId, isExpanded: true) }
        let id = model.addFolder(name: NodeDefaults.folderName, parentId: parentId)
        for nodeId in nodeIds.reversed() { model.moveNode(id: nodeId, toParentId: id, index: 0) }
        reloadRail()
        let anchor = railView.cellView(for: id) ?? railAnchor(for: parentId) ?? railView
        TextFieldFlyout.present(in: itemFlyouts, title: "New folder", value: NodeDefaults.folderName,
                                placeholder: "Folder name", from: anchor,
                                onSave: { [weak self] name in self?.model.renameNode(id: id, newName: name) },
                                onCancel: { [weak self] in
                                    guard nodeIds.isEmpty else { return }
                                    self?.model.deleteNodeFromAnyWorkspace(id: id)
                                })
    }

    /// Names a task in a flyout beside the rail; it's added only when saved.
    private func createTaskInRail(parentId: UUID?) {
        let anchor = railAnchor(for: parentId) ?? railView
        TextFieldFlyout.present(in: itemFlyouts, title: "New task", value: "", placeholder: "Task name", from: anchor,
                                onSave: { [weak self] title in
                                    guard let self else { return }
                                    if let parentId { self.model.setFolderExpanded(id: parentId, isExpanded: true) }
                                    self.model.addTask(title: title, parentId: parentId)
                                })
    }

    private func wireEmptyState() {
        let empty = nodeListViewController.emptyStateOverlay
        empty.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .paste, .addBookmarksMenu:
                self.importClipboardContent()
            case .clearSearch:
                self.clearSearch()
            case .showArchive:
                self.model.setArchiveExpanded(workspaceId: self.model.currentWorkspace.id, isExpanded: true)
            case .showArchivedMatches:
                self.revealArchivedMatches = true
                self.reloadData()
            }
        }
        empty.menuProvider = { [weak self] in self?.makeAddBookmarksMenu() ?? NSMenu() }
        empty.onDropText = { [weak self] text in self?.importText(text) }
    }

    private func clearSearch() {
        searchField.text = ""
        revealArchivedMatches = false
        searchCoordinator.updateQuery("")
        nodeListViewController.focusList()
    }

    private func makeAddBookmarksMenu() -> NSMenu {
        NewItemMenu.make(includePaste: true, includeImport: true, target: self, pasteEnabled: isPasteAvailable)
    }

    private var isPasteAvailable: Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return !ClipboardImportParser.parse(text).isEmpty
    }

    private func refreshPasteAvailability() {
        nodeListViewController.emptyStateOverlay.isPasteAvailable = isPasteAvailable
    }

    /// Tells VoiceOver once per query, after typing pauses, that nothing matched.
    private func announceNoMatches() {
        noMatchesAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .noMatches = self.lastEmptyStateKind,
                  let copy = EmptyStateCopy.make(self.lastEmptyStateKind, workspaceName: self.model.currentWorkspace.name, isTouch: false)
            else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: copy.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        noMatchesAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Adapts the chrome to the window width: rail keeps only icons, list and sidebar
    /// show everything, mosaic switches the list to tiles.
    private func applyElasticMode(_ mode: ElasticMode) {
        guard mode != elasticMode || !hasAppliedElasticMode else { return }
        hasAppliedElasticMode = true
        elasticMode = mode
        updatePageWidth()
        let rail = mode == .rail
        workspaceSwitcher.isHidden = rail
        searchField.isHidden = rail
        titleSettingsButton.isHidden = rail
        titleAddButton.isHidden = rail
        pasteButton.isHidden = rail
        updateFooterFit()
        nodeListViewController.elasticMode = mode
        updateSettingsConstraints()
        updateRailVisibility()
        reloadRail()
    }

    // MARK: - Rail

    /// The rail replaces the workspace chrome (header, search, list, bottom bar) and, like
    /// the mockup, drops the traffic lights. On Settings the rail shows workspace tiles.
    private func updateRailVisibility() {
        let rail = elasticMode == .rail
        let onSettings = model.state.isSettingsSelected
        let page: RailPage = rail ? (onSettings ? .settings : .workspace) : .none
        topBar.isHidden = rail
        contentStackTrailing.isActive = !rail
        // The rail only undoes its own hiding. Otherwise which page's content shows, mid-swipe
        // included, belongs to showSettingsContent / showWorkspaceContent.
        if rail {
            contentStack.isHidden = true
            if !settingsViewController.view.isHidden { settingsViewController.closeFlyouts() }
            settingsViewController.view.isHidden = true
            contentHiddenByRail = true
        } else if contentHiddenByRail {
            contentHiddenByRail = false
            settingsViewController.view.isHidden = !onSettings
            contentStack.isHidden = onSettings
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            view.window?.standardWindowButton(kind)?.isHidden = rail
        }
        transitionRail(to: page)
        updateOpenTabsPolling()
    }

    /// Swaps the workspace rail and the Settings rail. Between the two, the dots grow
    /// into tiles on the way in and the tiles shrink back into dots on the way out.
    private func transitionRail(to page: RailPage) {
        let previous = railPage
        guard page != previous else {
            guard !isRailMorphing else { return }
            railView.isHidden = page != .workspace
            settingsRail.view.isHidden = page != .settings
            return
        }
        railPage = page
        let animate = RailMotion.animates(windowVisible: view.window?.isVisible == true, swiping: isSwiping, reduceMotion: RailMotion.reduceMotion)
        let dotCenters = Dictionary(uniqueKeysWithValues: model.workspaces.enumerated().map {
            ($1.id, SettingsRailLayout.dotCenterY(at: $0))
        })
        if page != .settings { settingsRail.willLeave() }

        switch (previous, page) {
        case (.workspace, .settings) where animate:
            settingsRail.didEnter(from: lastShownWorkspaceId)
            settingsRail.reload()
            settingsRail.view.resetMorph()
            settingsRail.view.isHidden = false
            settingsRail.view.animateIn(dotCenters: dotCenters)
            settingsRail.view.takeKeyboard()
            isRailMorphing = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                railView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.isRailMorphing = false
                guard self.railPage == .settings else { return }
                self.railView.isHidden = true
                self.railView.alphaValue = 1
            })
        case (.settings, .workspace) where animate:
            railView.alphaValue = 0
            railView.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                railView.animator().alphaValue = 1
            }
            isRailMorphing = true
            settingsRail.view.animateOut(dotCenters: dotCenters) { [weak self] in
                guard let self else { return }
                self.isRailMorphing = false
                guard self.railPage == .workspace else { return }
                self.settingsRail.view.isHidden = true
                self.settingsRail.view.resetMorph()
            }
        default:
            if page == .settings {
                settingsRail.didEnter(from: lastShownWorkspaceId)
                settingsRail.reload()
                settingsRail.view.takeKeyboard()
            }
            settingsRail.view.resetMorph()
            railView.alphaValue = 1
            railView.isHidden = page != .workspace
            settingsRail.view.isHidden = page != .settings
        }
    }

    /// Open dots need the browsers' tab lists, read by OpenTabsMonitor only while a workspace
    /// with items (rail, list, sidebar or mosaic) is on a visible window.
    private func updateOpenTabsPolling() {
        let wanted = !model.state.isSettingsSelected
            && view.window?.occlusionState.contains(.visible) == true
            && model.activeWorkspace.items.contains(where: { !$0.isArchived })
        openTabs.setDemand(.list, wanted)
    }

    @objc private func windowOcclusionChanged(_ note: Notification) {
        updateOpenTabsPolling()
    }

    private func reloadRail() {
        guard elasticMode == .rail, !model.state.isSettingsSelected else { return }
        let ws = model.currentWorkspace
        railView.configure(
            workspaces: model.workspaces.map { RailView.WorkspaceDot(id: $0.id, name: $0.name, color: $0.colorId.color) },
            selectedId: ws.id,
            colorId: ws.colorId,
            items: ws.items
        )
        FaviconPrefetcher.shared.request(links: ws.items.flattenLinks().filter { !$0.isArchived }, in: ws.id)
    }

    private func selectWorkspaceAndPage(_ id: UUID) {
        guard let idx = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
        model.selectWorkspace(id: id)
        pageController.jumpToPage(idx + 1)
    }

    private func wireRail() {
        railView.onSelectWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        railView.onWorkspaceContextMenu = { [weak self] id, dot in
            self?.showWorkspaceMenu(for: id, in: dot, at: NSPoint(x: dot.bounds.width - 4, y: dot.isFlipped ? 0 : dot.bounds.height),
                                    editorAnchor: dot.bounds, edge: .besideWindow)
        }
        railView.onOpenLink = { [weak self] link in self?.openLink(link) }
        railView.onOpenFolder = { [weak self] folder in self?.openLinksInFolder(folder) }
        railView.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        railView.onCopySnippet = { [weak self] id in
            guard let self, case .snippet(let snippet)? = self.model.nodeById(id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet.content, forType: .string)
            Toast.show("Copied", in: self.view.window, duration: Toast.briefDuration)
        }
        railView.onStowTab = { [weak self] in self?.stowFrontTab() }
        railView.onReorder = { [weak self] id, index in self?.model.moveNode(id: id, toParentId: nil, index: index) }
        railView.onMoveToWorkspace = { [weak self] id, workspaceId in self?.model.moveNodeToWorkspace(id: id, workspaceId: workspaceId) }
        railView.onSettings = { [weak self] in self?.enterSettings() }
        railView.onNodeMenu = { [weak self] node, cell in
            guard let self, let menu = self.nodeMenu(for: node) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width - 4, y: cell.isFlipped ? 0 : cell.bounds.height), in: cell)
        }
        railView.onEditSnippet = { [weak self] id, anchor in self?.showSnippetEditor(id, from: anchor) }
        railView.onSetDueDate = { [weak self] id, anchor in self?.showDatePickerForTask(id, from: anchor) }
        railView.onNewTask = { [weak self] in self?.createTaskInRail(parentId: nil) }
        railView.onDropText = { [weak self] text, index in self?.addDroppedText(text, parentId: nil, index: index) }
        settingsRail.onLeave = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        settingsRail.onPreviewColor = { [weak self] colorId in
            self?.applyBackgroundColor(for: colorId ?? .settingsBackground)
        }
    }

    private func enterSettings() {
        model.selectSettings()
        pageController.jumpToPage(0)
    }

    /// ⌘, opens Settings; in the rail it also leaves, back to where you came from.
    func toggleSettings() {
        if elasticMode == .rail, model.state.isSettingsSelected {
            if let id = settingsRail.returnTarget { selectWorkspaceAndPage(id) }
        } else {
            enterSettings()
        }
    }

    /// The footer's keycap and tip follow the Stow front tab shortcut (none when cleared).
    @objc private func updateStowTabShortcut() {
        let shortcut = ShortcutStore().shortcut(for: .stowFrontTab)
        stowTabButton.keycapText = shortcut?.displayString
        stowTabButton.toolTip = "Save the front tab of the browser you were last in"
            + (shortcut.map { " (\($0.displayString), from any app)" } ?? "")
    }

    @objc private func stowTabTapped() {
        stowFrontTab()
    }

    /// Drops the keycap from "+ Stow this tab" when the footer is too narrow for it and
    /// Paste, then shows only the two icons, rather than clipping either.
    private func updateFooterFit() {
        guard let bottomBar, !contentStack.isHidden, bottomBar.bounds.width > 0 else { return }
        // Measured without changing what the buttons show; toggling them here to re-measure
        // would invalidate layout from inside viewDidLayout and loop.
        let fit = FooterButton.footerFit(width: bottomBar.bounds.width, stowFull: stowTabButton.fittingWidth(.full),
                                         stowTitle: stowTabButton.fittingWidth(.noKeycap), paste: pasteButton.fittingWidth(.noKeycap))
        if stowTabButton.fit != fit { stowTabButton.fit = fit }
        let pasteFit: FooterButton.Fit = fit == .icon ? .icon : .noKeycap
        if pasteButton.fit != pasteFit { pasteButton.fit = pasteFit }
    }

    private var bottomBar: NSView?

    /// Saves the front tab of the browser the user was last in to the active workspace (on
    /// Settings, the one you came from). Runs from the footer, the rail's "+" and the global
    /// Stow front tab shortcut.
    func stowFrontTab() {
        guard let bundleId = ActiveBrowserTracker.shared.lastActiveBundleId else { NSSound.beep(); return }
        let workspaceId = model.activeWorkspaceId
        Task.detached(priority: .userInitiated) { [weak self] in
            let tab = BrowserTabService.frontTab(bundleId: bundleId)
            await MainActor.run {
                guard let self else { return }
                guard let tab else { self.reportFrontTabUnavailable(); return }
                self.stow(url: tab.url, title: tab.title, into: workspaceId)
            }
        }
    }

    /// The front tab couldn't be read: say so when it's Automation permission (with a
    /// way to fix it), otherwise just beep.
    func reportFrontTabUnavailable() {
        guard let browser = AppPreferences.shared.automationDeniedBrowser() else { NSSound.beep(); return }
        Toast.show("Allow Stow to control \(browser)", action: Toast.Action(title: "Fix") {
            AppPreferences.shared.openAutomationSettings()
        }, in: view.window)
    }

    /// The one stow path: top of the workspace, once per page, then a title fetch.
    @discardableResult
    func stow(url: URL, title: String, into workspaceId: UUID?) -> AppModel.StowResult {
        let result = model.stowLink(url: url, title: title, workspaceId: workspaceId)
        switch result {
        case .added(let id):
            fetchTitleForNewLink(id: id, url: url)
        case .alreadyPresent(let id):
            let name = model.workspaces.first { ws in ws.items.flattenIds().contains(id) }?.name ?? model.activeWorkspace.name
            Toast.show("Already in \(name)", in: view.window, duration: Toast.briefDuration * 2)
        }
        return result
    }

    private func updateSettingsConstraints() {
        // Only while Settings is on screen (or mid-swipe toward it) does its width matter.
        let needed = (model.state.isSettingsSelected || isSwiping) && elasticMode != .rail
        if needed {
            NSLayoutConstraint.activate(parkedSettingsConstraints)
            parkedSettingsConstraints = []
        } else if parkedSettingsConstraints.isEmpty {
            parkedSettingsConstraints = settingsConstraints
            NSLayoutConstraint.deactivate(parkedSettingsConstraints)
        }
    }

    private var parkedSettingsConstraints: [NSLayoutConstraint] = []

    @objc private func titleSettingsTapped() {
        model.selectSettings()
        pageController.jumpToPage(0)
    }

    /// Ink for the title-row buttons; Settings wears the selected pill on its page.
    private func updateTitleButtons(colors: StowTheme.Colors) {
        let onSettings = model.state.isSettingsSelected
        titleSettingsButton.layer?.backgroundColor = view.resolvedCGColor(onSettings ? colors.inkPrimary : .clear)
        titleSettingsButton.contentTintColor = onSettings ? colors.surface : colors.inkPrimary
        titleAddButton.contentTintColor = colors.inkPrimary
    }

    @objc private func showNewItemMenu() {
        let menu = NewItemMenu.make(includePaste: false, includeImport: false, target: self)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: titleAddButton.bounds.height + 4), in: titleAddButton)
    }

    @objc private func importClipboardContent() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        importText(pasted)
    }

    /// Adds every link, task or snippet found in `text` to the current workspace.
    private func importText(_ text: String) {
        addParsedItems(text, parentId: nil, index: nil)
    }

    /// Text dropped on the list or the rail: its links (and any tasks or snippets) go in
    /// at the drop position, in order, and the links fetch their titles.
    private func addDroppedText(_ text: String, parentId: UUID?, index: Int) {
        addParsedItems(text, parentId: parentId, index: index)
    }

    /// Adds what ClipboardImportParser finds in `text` under `parentId`: at the end, or
    /// from `index` on.
    private func addParsedItems(_ text: String, parentId: UUID?, index: Int?) {
        var position = index
        for item in ClipboardImportParser.parse(text) {
            let id: UUID
            switch item {
            case .task(let title, let isCompleted):
                id = model.addTask(title: title, parentId: parentId)
                if isCompleted { model.toggleTaskCompletion(id: id) }
            case .link(let url, let defaultTitle):
                id = model.addLink(urlString: url.absoluteString, title: defaultTitle, parentId: parentId)
                fetchTitleForNewLink(id: id, url: url)
            case .snippet(let title, let content):
                id = model.addSnippet(title: title, content: content, language: nil, parentId: parentId)
            }
            if let at = position {
                model.moveNode(id: id, toParentId: parentId, index: at)
                position = at + 1
            }
        }
    }

    @objc func paste(_ sender: Any?) {
        // Don't intercept paste when a text field is active (inline rename, search)
        if nodeListViewController.inlineRenameNodeId != nil { return }
        if view.window?.firstResponder is NSTextView { return }
        // Don't paste when settings are showing
        if model.state.isSettingsSelected { return }
        importClipboardContent()
    }

    /// Switches to the link's tab if it's open in any browser; otherwise opens it in the
    /// workspace's "Opens in" browser (by default the browser you're using). Holding Option
    /// opens a fresh tab instead. `override` is a one-off Open in ▸ choice from the link's menu.
    func openLink(_ link: Link, in override: OpensIn? = nil) {
        guard let url = URL(string: link.url) else { return }
        let target = override.map {
            LinkTarget(bundleId: $0.bundleId, profile: $0.profile)
        } ?? LinkTarget.forWorkspace(model.activeWorkspaceId)
        Task.detached(priority: .userInitiated) {
            if target.focusesOpenTab, await BrowserTabService.focusIfOpen(url: url) { return }
            await MainActor.run { BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile) }
        }
    }

    private func openLinksInFolder(_ folder: Folder) {
        let links = collectLinks(in: folder)
        guard !links.isEmpty else { return }
        let target = LinkTarget.forWorkspace(model.activeWorkspaceId)
        // One tabs snapshot covers every link — avoids 20 detached Tasks each
        // re-querying every running browser on bulk open.
        Task.detached(priority: .userInitiated) {
            let tabs = await BrowserTabService.tabsByCanonicalURL()
            for link in links {
                guard let url = URL(string: link.url) else { continue }
                let key = BrowserTabService.canonicalize(url)
                if target.focusesOpenTab, let tab = tabs[key], BrowserTabService.focus(tab: tab) { continue }
                await MainActor.run { BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile) }
            }
        }
    }

    private func collectLinks(in folder: Folder) -> [Link] {
        folder.children.flattenLinks()
    }

    // MARK: - URL Utilities

    private func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { [weak self] title in
            guard let self, let title else { return }
            _ = self.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }

    @objc private func handleFaviconUpdate(_ notification: Notification) {
        guard let linkId = notification.userInfo?["linkId"] as? UUID,
              let path = notification.userInfo?["path"] as? String else { return }
        model.updateLinkFaviconPath(id: linkId, path: path)
    }

    // MARK: - Task & Snippet Actions

    private func copySnippetToClipboard(_ snippetId: UUID) {
        guard let node = model.nodeById(snippetId), case .snippet(let snippet) = node else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.content, forType: .string)
        nodeListViewController.showCopiedFeedback(for: snippetId)
    }

    /// The due date flyout beside the task's row, or beside `anchor` (a rail view).
    func showDatePickerForTask(_ taskId: UUID, from anchor: NSView? = nil) {
        guard case .task(let task)? = model.nodeById(taskId), let anchor = anchor ?? anchorView(for: taskId) else { return }
        DueDateFlyout.present(in: itemFlyouts, title: task.title, dueDate: task.dueDate, from: anchor) { [weak self] date in
            self?.model.updateTaskDueDate(id: taskId, dueDate: date)
        }
    }

    /// The snippet editor flyout beside the snippet's row, or beside `anchor` (a rail
    /// view). `discardOnCancel` takes a snippet that was just added away again.
    func showSnippetEditor(_ snippetId: UUID, from anchor: NSView? = nil, discardOnCancel: Bool = false) {
        let editor = snippetEditor
        // Moving to another snippet keeps the edits to the one on screen, as a click away does.
        if itemFlyouts.isOpen(.snippet) { editor.save() }
        guard case .snippet(let snippet)? = model.nodeById(snippetId), let anchor = anchor ?? anchorView(for: snippetId) else { return }
        var saved = false
        editor.load(snippet)
        editor.onSave = { [weak self] updatedTitle, updatedContent, updatedLanguage in
            guard let self else { return }
            saved = true
            let trimmedTitle = updatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty && trimmedTitle != snippet.title {
                self.model.renameNode(id: snippetId, newName: trimmedTitle)
            }
            self.model.updateSnippetContent(id: snippetId, content: updatedContent)
            self.model.updateSnippetLanguage(id: snippetId, language: updatedLanguage)
            self.model.autoDeriveTitleIfNeeded(id: snippetId)
        }
        editor.onClose = { [weak self] in
            guard let self else { return }
            self.itemFlyouts.close(.snippet)
            if discardOnCancel, !saved { self.model.deleteNodeFromAnyWorkspace(id: snippetId) }
        }
        editor.frame.size = SnippetEditorView.size
        guard itemFlyouts.show(.snippet, content: editor, size: SnippetEditorView.size, from: anchor, topInset: 30,
                               onEscape: { [weak editor] in editor?.cancel() },
                               onOutsideClick: { [weak editor] in editor?.save() }) else { return }
        editor.focusContent()
    }

    // MARK: - Bulk Operations

    private func handleBulkCopyLinks(_ nodeIds: [UUID]) {
        let nodes = nodeIds.compactMap { id in
            model.findNode(id: id, in: model.currentWorkspace.items)
        }
        let urls = nodes.compactMap { node -> String? in
            if case .link(let link) = node {
                return link.url
            }
            return nil
        }

        guard !urls.isEmpty else { return }

        let joined = urls.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    // MARK: - Keyboard Hotkeys

    /// Handles plain a-z key presses for item activation.
    /// Returns true if the event was consumed.
    /// Holding ⌘ alone reveals the a–z jump letters after a short pause, so quick ⌘
    /// shortcuts never flash them. Releasing ⌘ hides them again.
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == .command {
            // Modifier events often arrive without a window, so check key status instead.
            guard commandHoldReveal == nil, !isCommandHoldJump, acceptsListShortcuts,
                  view.window?.isKeyWindow == true,
                  !model.state.isSettingsSelected, !isSwiping,
                  !(view.window?.firstResponder is NSTextView),
                  nodeListViewController.hasNodeRows,
                  !nodeListViewController.isJumpModeActive else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.commandHoldReveal = nil
                self.isCommandHoldJump = true
                self.nodeListViewController.jumpLetters = Self.commandSafeLetters
                self.nodeListViewController.isJumpModeActive = true
                self.setShortcutHintsVisible(true)
            }
            commandHoldReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } else {
            endCommandHold()
        }
    }

    private func endCommandHold() {
        commandHoldReveal?.cancel()
        commandHoldReveal = nil
        if isCommandHoldJump {
            isCommandHoldJump = false
            nodeListViewController.isJumpModeActive = false
            nodeListViewController.jumpLetters = Array("abcdefghijklmnopqrstuvwxyz")
            setShortcutHintsVisible(false)
        }
    }

    /// Letters free of ⌘ shortcuts (⌘A C F H J M N Q T V W X Z and system ones are taken),
    /// so ⌘ + letter can open a row without stealing a command.
    private static let commandSafeLetters: [Character] = Array("bdegiklopsruy")

    /// Shows keycaps on every control that has a shortcut while ⌘ is held.
    private func setShortcutHintsVisible(_ visible: Bool) {
        pasteButton.keycapText = visible ? "⌘V" : nil
        workspaceSwitcher.showsShortcutHints = visible
        searchField.showsShortcutHint = visible
    }

    /// ⌘ + letter while the hold hints are showing opens that row. Any key pressed
    /// before the hints appear is a normal shortcut and cancels the reveal.
    private func handleCommandHoldKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        guard isCommandHoldJump else {
            commandHoldReveal?.cancel()
            commandHoldReveal = nil
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let letter = chars.first, let index = nodeListViewController.rowIndex(forJumpLetter: letter) else {
            // Not a row letter: let the menu shortcut (⌘V, ⌘F, ⌘1…) run as usual.
            endCommandHold()
            return false
        }
        endCommandHold()
        activateRow(at: index)
        return true
    }

    private func activateRow(at index: Int) {
        guard let node = nodeListViewController.visibleNode(at: index) else { return }
        switch node {
        case .link(let link):
            openLink(link)
        case .folder(let folder):
            if !searchCoordinator.isSearchActive {
                model.setFolderExpanded(id: folder.id, isExpanded: !folder.isExpanded)
            }
        case .task(let task):
            model.toggleTaskCompletion(id: task.id)
        case .snippet(let snippet):
            copySnippetToClipboard(snippet.id)
        }
    }

    private func handlePlainKeyEvent(_ event: NSEvent) -> Bool {
        guard event.window === view.window, view.window?.isKeyWindow == true else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .capsLock || flags == .shift else { return false }
        if event.keyCode == 53, elasticMode == .rail, model.state.isSettingsSelected, !isSwiping,
           !(view.window?.firstResponder is NSTextView) {
            return settingsRail.handleEscape()
        }
        guard !model.state.isSettingsSelected, !isSwiping else { return false }
        let isEditingText = view.window?.firstResponder is NSTextView

        // Esc leaves jump mode, or clears an active search and returns to the list.
        if event.keyCode == 53 {
            if nodeListViewController.isJumpModeActive {
                nodeListViewController.isJumpModeActive = false
                return true
            }
            if searchCoordinator.isSearchActive || isEditingText && searchField.isFocused {
                clearSearch()
                return true
            }
            return false
        }

        if isEditingText { return false }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }

        if chars == "/" && flags.isEmpty && acceptsListShortcuts {
            focusSearch()
            return true
        }

        // Letters activate rows only in jump mode, so a stray keystroke can't open a link.
        guard nodeListViewController.isJumpModeActive, flags.isEmpty || flags == .capsLock,
              scalar.value >= 97 && scalar.value <= 122 else { return false }

        nodeListViewController.isJumpModeActive = false
        if let index = nodeListViewController.rowIndex(forJumpLetter: Character(chars)) {
            activateRow(at: index)
        }
        return true
    }

    @objc private func tintModeChanged() {
        nodeListViewController.tintMode = StowTheme.displayTint
        workspaceSwitcher.workspaceColor = workspaceSwitcher.workspaceColor
        applyBackgroundColor(for: displayedColorId)
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        refreshPasteAvailability()
        updateOpenTabsPolling()
        openTabs.refreshNow()
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        endCommandHold()
    }

    private var hasFocusedListOnFirstKey = false

    @objc private func windowDidFirstBecomeKey(_ note: Notification) {
        guard !hasFocusedListOnFirstKey else { return }
        hasFocusedListOnFirstKey = true
        view.window?.makeFirstResponder(nodeListViewController.focusTarget)
    }

    /// Jump letters, ⌘-hold and / act on the list, which the rail hides.
    var acceptsListShortcuts: Bool { elasticMode != .rail }

    /// The workspace whose editor is open in the Settings rail.
    var settingsRailEditingId: UUID? { settingsRail.editingId }

    /// Whether the title-bar strip is renaming a workspace, or about to.
    var isWorkspaceStripRenaming: Bool { workspaceSwitcher.isInlineRenaming || pendingWorkspaceRenameId != nil }

    /// ⌘F. In the rail the panel first widens to the list, where the search field is.
    func focusSearch() {
        guard !model.state.isSettingsSelected else { return }
        if elasticMode == .rail { widenToList() }
        guard elasticMode != .rail else { return }
        nodeListViewController.isJumpModeActive = false
        searchField.focus()
    }

    /// Grows the window from the rail to list width, toward whichever side has room.
    private func widenToList() {
        guard let window = view.window else { return }
        let extra = Self.listWidthFromRail - view.bounds.width
        guard extra > 0 else { return }
        var frame = window.frame
        frame.size.width += extra
        if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX { frame.origin.x -= extra }
        window.setFrame(frame, display: true)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private static let listWidthFromRail: CGFloat = 220

    func toggleJumpMode() {
        guard !model.state.isSettingsSelected else { return }
        guard acceptsListShortcuts, nodeListViewController.hasNodeRows else {
            NSSound.beep()
            return
        }
        nodeListViewController.isJumpModeActive.toggle()
    }

    /// Switches to workspace at the given index (0-based). Called from AppDelegate Cmd+1-9.
    func switchToWorkspace(atIndex index: Int) {
        guard index >= 0, index < model.workspaces.count else { return }
        let workspace = model.workspaces[index]
        model.selectWorkspace(id: workspace.id)
        pageController.jumpToPage(index + 1)
    }

    // MARK: - Swipe Transition Helpers

    private func captureContentSnapshot() -> NSImageView? {
        let sourceView: NSView
        if model.state.isSettingsSelected {
            sourceView = settingsViewController.view
        } else {
            sourceView = nodeListViewController.view
        }
        guard !sourceView.isHidden else { return nil }

        let bounds = sourceView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        guard let bitmapRep = sourceView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        sourceView.cacheDisplay(in: bounds, to: bitmapRep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleNone
        imageView.wantsLayer = true

        let frameInView = sourceView.convert(bounds, to: self.view)
        imageView.frame = frameInView

        return imageView
    }

    private func preloadIncomingPage(_ targetPageIndex: Int) {
        guard targetPageIndex != preloadedPageIndex else { return }
        preloadedPageIndex = targetPageIndex

        let workspaceCount = model.workspaces.count

        if isRailSwipe {
            // The rail keeps its dots; only the items under them change to the incoming page's.
            let index = RailSwipe.workspaceIndex(forPage: targetPageIndex, workspaceCount: model.workspaces.count)
            railView.previewItems(index.map { model.workspaces[$0].items } ?? [])
            return
        }
        if targetPageIndex == 0 {
            showSettingsContent()
        } else if targetPageIndex >= 1 && targetPageIndex <= workspaceCount {
            showWorkspaceContent()
            let workspaceIdx = targetPageIndex - 1
            let workspace = model.workspaces[workspaceIdx]
            let filteredNodes = searchCoordinator.filter(nodes: workspace.items)
            nodeListViewController.isSearchActive = searchCoordinator.isSearchActive
            nodeListViewController.reloadData(with: filteredNodes, forceExpand: false, animated: false)
        }
        // Add-new page: no content to show
    }

    private func beginSwipeTransition() {
        nodeListViewController.emptyStateOverlay.settle()
        updateSettingsConstraints()
        swipeStartPageIndex = currentPageIndex()
        preloadedPageIndex = nil
        swipeDirection = 0

        if isRailSwipe {
            railOutgoingSnapshot = railView.snapshotItems()
            railView.setItemsOffset(view.bounds.width)
        } else if let snapshot = captureContentSnapshot() {
            outgoingSnapshotView = snapshot
            view.addSubview(snapshot)
        }
    }

    private func cleanupSwipeTransition() {
        outgoingSnapshotView?.removeFromSuperview()
        outgoingSnapshotView = nil
        railOutgoingSnapshot?.removeFromSuperview()
        railOutgoingSnapshot = nil
        railView.setItemsOffset(0)
        preloadedPageIndex = nil
        swipeDirection = 0
        nodeListViewController.view.layer?.transform = CATransform3DIdentity
        nodeListViewController.view.alphaValue = 1.0
    }

    /// Whether the current swipe is between two workspace pages (not settings or add-new).
    private var isWorkspaceToWorkspaceSwipe: Bool {
        let target = swipeStartPageIndex + swipeDirection
        let workspaceCount = model.workspaces.count
        return swipeStartPageIndex >= 1 && swipeStartPageIndex <= workspaceCount
            && target >= 1 && target <= workspaceCount
    }
}

// MARK: - ScrollWheelPageDelegate

extension MainViewController: ScrollWheelPageDelegate {

    func pagerDidUpdateOffset(_ offset: CGFloat) {
        // Swipe detection
        if !isSwiping {
            let isFractional = abs(offset - offset.rounded()) > 0.001
            if isFractional {
                isSwiping = true
                beginSwipeTransition()
            } else {
                applyBackgroundColor(for: colorForPage(Int(offset.rounded())))
                return
            }
        }

        let startPage = CGFloat(swipeStartPageIndex)
        let delta = offset - startPage
        let width = contentAreaWidth

        // Direction tracking — detect changes and preload incoming
        let newDirection: Int = delta > 0.001 ? 1 : (delta < -0.001 ? -1 : 0)
        if newDirection != 0 && newDirection != swipeDirection {
            swipeDirection = newDirection
            let targetPage = swipeStartPageIndex + newDirection
            preloadIncomingPage(targetPage)
        }

        if isRailSwipe {
            let t = RailSwipe.translations(delta: delta, direction: swipeDirection == 0 ? 1 : swipeDirection, width: view.bounds.width)
            railOutgoingSnapshot?.layer?.transform = CATransform3DMakeTranslation(t.outgoing, 0, 0)
            railView.setItemsOffset(t.incoming)
        }

        // Position outgoing snapshot (slides away from center)
        let txOut = -delta * width
        outgoingSnapshotView?.layer?.transform = CATransform3DMakeTranslation(txOut, 0, 0)
        outgoingSnapshotView?.alphaValue = 1.0

        // Position incoming content
        let targetPage = swipeStartPageIndex + swipeDirection
        let isAddNewPage = targetPage >= totalPageCount() - 1

        if targetPage < 0 {
            // Edge bounce past first page: hide source view so it doesn't
            // show through behind the translating snapshot.
            settingsViewController.view.isHidden = true
        } else {
            let swipeFromWorkspace = swipeStartPageIndex >= 1
                && swipeStartPageIndex <= model.workspaces.count

            if isAddNewPage {
                // Add-new page: hide incoming content, just show background
                if swipeFromWorkspace {
                    nodeListViewController.view.alphaValue = 0
                } else {
                    contentStack.alphaValue = 0
                }
                settingsViewController.view.alphaValue = 0
            } else if swipeDirection != 0 {
                let incomingView: NSView
                if targetPage == 0 {
                    incomingView = settingsViewController.view
                } else if isWorkspaceToWorkspaceSwipe {
                    incomingView = nodeListViewController.view
                } else {
                    incomingView = contentStack
                }
                let txIn: CGFloat
                if delta > 0 {
                    txIn = (1.0 - delta) * width
                } else {
                    txIn = (-1.0 - delta) * width
                }
                incomingView.layer?.transform = CATransform3DMakeTranslation(txIn, 0, 0)
                incomingView.alphaValue = 1.0
            }
        }

        // Interpolate background color
        let fromPage = max(0, Int(floor(offset)))
        let toPage = min(totalPageCount() - 1, fromPage + 1)
        let fraction = offset - CGFloat(fromPage)

        let fromColor = resolvedColor(colorForPage(fromPage).adaptiveBackgroundColor)
        let toColor = resolvedColor(colorForPage(toPage).adaptiveBackgroundColor)

        if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
            view.layer?.backgroundColor = blended.cgColor
            view.window?.backgroundColor = blended
        }

        // Update workspace switcher sliding highlight
        workspaceSwitcher.visualPageOffset = offset

        // Continuous haptic while dragging into the add-new zone
        let lastWorkspacePage = CGFloat(totalPageCount() - 2)
        if offset > lastWorkspacePage + 0.01 {
            let now = CACurrentMediaTime()
            if now - lastAddNewHapticTime >= 0.05 {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                lastAddNewHapticTime = now
            }
        }
    }

    /// Flattens a dynamic color to a concrete sRGB color in the current appearance.
    private func resolvedColor(_ color: NSColor) -> NSColor {
        var result = color
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    func pagerDidSnapToPage(_ pageIndex: Int) {
        workspaceSwitcher.visualPageOffset = nil

        cleanupSwipeTransition()

        // Reset transforms and alpha on all content views
        contentStack.layer?.transform = CATransform3DIdentity
        settingsViewController.view.layer?.transform = CATransform3DIdentity
        nodeListViewController.view.layer?.transform = CATransform3DIdentity
        contentStack.alphaValue = 1.0
        settingsViewController.view.alphaValue = 1.0
        nodeListViewController.view.alphaValue = 1.0

        let pageCount = totalPageCount()

        if pageIndex == 0 {
            model.selectSettings()
        } else if pageIndex >= pageCount - 1 {
            isSwiping = false
            if needsReloadAfterSwipe { reloadData(animated: false) }
            promptCreateWorkspace()
            return
        } else {
            let workspaceIdx = pageIndex - 1
            if workspaceIdx < model.workspaces.count {
                model.selectWorkspace(id: model.workspaces[workspaceIdx].id)
            }
        }

        // The swipe ends before reloading, or reloadData would skip it as mid-swipe. This
        // reload also covers anything recorded in needsReloadAfterSwipe. The list holds the
        // previewed page, so there's nothing meaningful to animate from.
        isSwiping = false
        reloadData(animated: false)
        applyBackgroundColor(for: colorForPage(pageIndex))
    }

    func pagerPageCount() -> Int {
        totalPageCount()
    }

    func pagerCurrentPage() -> Int {
        currentPageIndex()
    }
}

// MARK: - NewItemMenuTarget

extension MainViewController: NewItemMenuTarget {
    func newFolderFromMenu(_ sender: Any?) { createFolderAndBeginRename(parentId: nil) }
    func newTaskFromMenu(_ sender: Any?) { createTaskAndBeginRename(parentId: nil) }
    func newSnippetFromMenu(_ sender: Any?) { createSnippetAndBeginRename(parentId: nil) }
    func newWorkspaceFromMenu(_ sender: Any?) { promptCreateWorkspace() }
    func pasteFromMenu(_ sender: Any?) { importClipboardContent() }
    func importFromArcFromMenu(_ sender: Any?) { ImportCoordinator.shared.importFromArc() }
}
