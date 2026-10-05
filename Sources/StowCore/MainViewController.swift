import AppKit
import Combine
import ObjectiveC


@MainActor
final class MainViewController: NSViewController {
    let model: AppModel

    // Coordinators and child view controllers
    let searchCoordinator = SearchCoordinator()
    let nodeListViewController = NodeListViewController()
    let settingsViewController = SettingsContentViewController()

    // UI Components
    let workspaceSwitcher = WorkspaceStripView()
    let titleSettingsButton = NSButton()
    /// The workspace rail.
    private(set) lazy var rail = RailCoordinator(main: self)
    /// Opening and stowing links.
    private(set) lazy var links = LinkActions(model: model, window: { [weak self] in self?.view.window })
    var railView: RailView { rail.railView }
    /// Rename, Edit URL, due date and snippet flyouts, for the list, the mosaic and the rail.
    let itemFlyouts = ItemFlyouts()
    /// The one snippet editor, moved between snippets.
    private lazy var snippetEditor = SnippetEditorView()
    /// The one workspace editor, for a right-click on any workspace (rail dots, strip tabs,
    /// "More workspaces" rows, the Tabline chip and its list) and for "New workspace…".
    private(set) lazy var workspaceEditor = makeWorkspaceEditor()
    /// The app sheet beside the rail, from its gear: Settings at rail width.
    private(set) lazy var appSheet = makeAppSheet()
    private var isAppSheetLoaded = false
    private var isPreviewingWorkspaceColor = false
    nonisolated(unsafe) private var hostClickMonitor: Any?
    /// The workspace on screen before Settings, for the 4pt dot and the way back.
    private(set) var lastShownWorkspaceId: UUID?
    /// Released in rail so the hidden list's minimum width can't hold the window wider than the rail.
    var contentStackTrailing: NSLayoutConstraint!
    private(set) var elasticMode: ElasticMode = .sidebar
    /// The first layout applies the width's mode even when it matches the default.
    private var hasAppliedElasticMode = false
    /// The Settings page's own width (~240pt) would stop the window narrowing to a rail,
    /// so its constraints are switched off whenever Settings isn't showing.
    private var settingsConstraints: [NSLayoutConstraint] {
        view.constraints.filter { ($0.firstItem as? NSView) === settingsViewController.view || ($0.secondItem as? NSView) === settingsViewController.view }
    }
    let titleAddButton = NSButton()
    let searchField = SearchBarView(style: .defaultSearch)
    private let stowTabButton = FooterButton(title: "+ Stow this tab", keycap: "⌥⌘S", symbolName: "plus")
    let pasteButton = FooterButton(title: "Paste", symbolName: "doc.on.clipboard")
    /// Open browser tabs, for the rail's and the list's open dots.
    private let openTabs = OpenTabsMonitor.shared
    private var openTabsSubscription: AnyCancellable?
    private var modelSubscription: AnyCancellable?

    // Page navigation
    private let pageController = ScrollWheelPageController()
    var topBar = NSView()

    // Content containers (show/hide for page switching)
    let contentStack = NSStackView()

    /// Swipes between pages.
    private(set) lazy var pageSwipe = PageSwipeCoordinator(main: self)
    var isSwiping: Bool { pageSwipe.isSwiping }

    /// Jump letters, ⌘-hold, "/" and Esc.
    private lazy var keyboard = KeyboardRouter(main: self)

    // State
    private var isReloadScheduled = false
    private var hasLoaded = false
    private var lastWorkspaceId: UUID?
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
        NotificationCenter.default.removeObserver(self)
        if let hostClickMonitor { NSEvent.removeMonitor(hostClickMonitor) }
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
        tabline.onOpenLink = { [weak self] link in self?.links.openLink(link) }
        tabline.onSelectWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        // The Tabline shows the active workspace, so that's where its ghost tab is stowed.
        tabline.onStowURL = { [weak self] url, title, toast in
            self?.links.stow(url: url, title: title, into: tabline.content.workspaceId, toast: toast)
        }
        // Task ids are found in whichever workspace holds them.
        tabline.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        // The editor opens away from the edge the strip rides, like its other flyouts.
        tabline.onEditWorkspace = { [weak self] id, view, rect in
            self?.editWorkspace(id, from: view, rect: rect, edge: tabline.flyoutEdge == .above ? .above : .below)
        }
        tabline.onNewWorkspace = { [weak self] view, rect in
            self?.beginNewWorkspace(from: view, rect: rect, edge: tabline.flyoutEdge == .above ? .above : .below)
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

        keyboard.start()
        installHostClickMonitor()
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
            self?.links.openLink(link, in: choice)
        }
        workspaceSwitcher.onWorkspaceRightClick = { [weak self] workspaceId, anchor in
            self?.editWorkspace(workspaceId, from: anchor, edge: .below)
        }
        workspaceSwitcher.onWorkspaceReorder = { [weak self] workspaceId, index in
            self?.model.reorderWorkspace(id: workspaceId, toIndex: index)
        }
        for (button, symbol, label, action) in [
            (titleSettingsButton, StowSymbols.settings, "Settings", #selector(titleSettingsTapped)),
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
        rail.wireRail()

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
        ])

        wireEmptyState()

        // Setup page controller
        pageController.delegate = pageSwipe
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
                self.links.openLink(link)
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
                self.links.fetchTitleForNewLink(id: nodeId, url: url)
            }
        }

        nodeListViewController.onOpenFolderLinks = { [weak self] folderId in
            guard let self, let node = self.model.nodeById(folderId), case .folder(let folder) = node else { return }
            self.links.openLinksInFolder(folder)
        }

        nodeListViewController.onOpenLinkInNewTab = { [weak self] linkId in
            guard let self, case .link(let link)? = self.model.nodeById(linkId) else { return }
            self.links.openLink(link, newTab: true)
        }

        nodeListViewController.onBulkOpenLinks = { [weak self] nodeIds in
            guard let self else { return }
            for nodeId in nodeIds {
                if let node = self.model.findNode(id: nodeId, in: self.model.currentWorkspace.items),
                   case .link(let link) = node {
                    self.links.openLink(link)
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
        actions.openIn = { [weak self] link, choice in self?.links.openLink(link, in: choice) }
        actions.openFolder = { [weak self] folder in self?.links.openLinksInFolder(folder) }
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

    /// Move to › New workspace…: the items go into the new workspace when it's created.
    func moveToNewWorkspace(_ nodeIds: [UUID]) {
        guard !nodeIds.isEmpty else { return }
        beginNewWorkspace(moving: nodeIds)
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
    func reloadData(animated: Bool = true) {
        if isSwiping {
            pageSwipe.needsReloadAfterSwipe = true
            return
        }
        pageSwipe.needsReloadAfterSwipe = false

        // Cancel any in-progress inline rename if node is deleted
        if let renameId = nodeListViewController.inlineRenameNodeId,
           model.nodeById(renameId) == nil {
            nodeListViewController.cancelInlineRename()
        }

        // The rail has no Settings page; it goes back to the workspace you came from.
        if elasticMode == .rail, model.state.isSettingsSelected {
            model.selectWorkspace(id: model.activeWorkspaceId)
            pageController.jumpToPage(currentPageIndex())
        }

        let isNodeRenaming = nodeListViewController.inlineRenameNodeId != nil
        let isWorkspaceRenaming = workspaceSwitcher.isInlineRenaming

        // Skip workspace menu rebuild if mid-rename to preserve text field focus
        if !isWorkspaceRenaming {
            reloadWorkspaceStrip()
        }

        settingsViewController.notifyWorkspacesChanged()
        // The editor shows each change as it's made.
        if workspaceEditor.isOpen { workspaceEditor.refresh() }

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
        } else {
            lastShownWorkspaceId = currentWorkspaceId
            showWorkspaceContent()
            // A custom colour being dragged in the editor previews on the page behind it.
            applyBackgroundColor(for: workspaceEditor.shownColor(of: model.currentWorkspace))
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
            rail.reloadRail()
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

    private func reloadWorkspaceStrip() {
        let workspaces = model.workspaces

        workspaceSwitcher.workspaces = workspaces.map { workspace in
            WorkspaceStripView.WorkspaceItem(
                id: workspace.id,
                name: workspace.name,
                colorId: workspaceEditor.shownColor(of: workspace)
            )
        }

        workspaceSwitcher.isSettingsSelected = model.state.isSettingsSelected

        if model.state.isSettingsSelected {
            workspaceSwitcher.selectedWorkspaceId = nil
            workspaceSwitcher.workspaceColor = .settingsBackground
        } else {
            let selectedId = model.currentWorkspace.id
            workspaceSwitcher.selectedWorkspaceId = selectedId
            workspaceSwitcher.workspaceColor = workspaceEditor.shownColor(of: model.currentWorkspace)
        }
    }

    func applyBackgroundColor(for colorId: WorkspaceColorId) {
        let bgColor = colorId.adaptiveBackgroundColor
        view.layer?.backgroundColor = view.resolvedCGColor(bgColor)
        view.window?.backgroundColor = bgColor
        displayedColorId = colorId
        applyChromeColors(StowTheme.colors(for: colorId, tint: StowTheme.displayTint))
        updateSettingsConstraints()
    }

    /// Tints the chrome that sits on the page background: search, title and footer buttons.
    /// Mid-swipe it gets the same blend of the two workspaces as the background.
    func applyChromeColors(_ colors: StowTheme.Colors) {
        searchField.colors = colors
        updateTitleButtons(colors: colors)
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
    func totalPageCount() -> Int {
        model.workspaces.count + 2
    }

    /// Returns the current page index based on model state.
    func currentPageIndex() -> Int {
        if model.state.isSettingsSelected { return 0 }
        if let idx = model.workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }) {
            return idx + 1
        }
        return 1
    }

    /// Returns the color for a page index.
    func colorForPage(_ pageIndex: Int) -> WorkspaceColorId {
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
    var contentAreaWidth: CGFloat {
        view.bounds.width - 2 * LayoutConstants.windowPadding
    }

    /// Syncs the page controller's page width with the current content area width.
    private func updatePageWidth() {
        let width = contentAreaWidth
        if width > 0 {
            pageController.pageWidth = RailSwipe.pageWidth(contentWidth: width, isRail: elasticMode == .rail)
            pageController.maxPagesPerSwipe = elasticMode == .rail ? 1 : nil
            pageController.firstPage = elasticMode == .rail ? 1 : 0
        }
    }

    // MARK: - Content Show/Hide

    func showSettingsContent() {
        contentStack.isHidden = true
        // The rail has no Settings page: its gear opens the app sheet instead.
        settingsViewController.view.isHidden = elasticMode == .rail
        rail.updateRailVisibility()
    }

    func showWorkspaceContent() {
        if !settingsViewController.view.isHidden { settingsViewController.closeFlyouts() }
        settingsViewController.view.isHidden = true
        contentStack.isHidden = false
        rail.updateRailVisibility()
    }

    // MARK: - Workspace Management

    typealias WorkspaceEditorEdge = WorkspaceEditorController.AnchorEdge

    private func makeWorkspaceEditor() -> WorkspaceEditorController {
        let editor = WorkspaceEditorController(model: model)
        editor.onOpenWorkspace = { [weak self] id in
            self?.workspaceEditor.close()
            self?.selectWorkspaceAndPage(id)
        }
        editor.onCreated = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        // A swipe past the last page that ends in Esc snaps back to the workspace it left.
        editor.onNewCancelled = { [weak self] in
            guard let self else { return }
            self.pageController.jumpToPage(self.currentPageIndex())
            self.reloadData(animated: false)
        }
        // A custom colour's drag previews on the page, the strip and the rail; closing
        // without one puts the real colours back.
        editor.onPreviewColor = { [weak self] _ in
            self?.isPreviewingWorkspaceColor = true
            self?.reloadData(animated: false)
        }
        editor.onClose = { [weak self] in
            guard let self, self.isPreviewingWorkspaceColor else { return }
            self.isPreviewingWorkspaceColor = false
            self.reloadData(animated: false)
        }
        return editor
    }

    /// Opens the workspace editor on `workspaceId`, anchored to `view` (`rect` in it, or
    /// its bounds). The anchor is followed while it's on screen; once it's gone (a flyout
    /// row that closed) the editor stays where it was. A view in a flyout parents the
    /// editor to the window under that flyout.
    func editWorkspace(_ workspaceId: UUID, from view: NSView, rect: NSRect? = nil, edge: WorkspaceEditorEdge,
                       focusName: Bool = false) {
        workspaceEditor.open(workspaceId, placement: anchoredPlacement(view, rect: rect, edge: edge), focusName: focusName)
    }

    /// "New workspace…": the editor on a workspace that exists only once it's committed,
    /// with its name empty and focused, beside the rail's workspace chip or under the
    /// title "+".
    func beginNewWorkspace(moving nodeIds: [UUID] = []) {
        if elasticMode == .rail {
            beginNewWorkspace(moving: nodeIds, from: railView.workspaceChip, edge: .besideWindow)
        } else if !titleAddButton.isHidden {
            beginNewWorkspace(moving: nodeIds, from: titleAddButton, edge: .below)
        } else {
            beginNewWorkspace(moving: nodeIds, from: workspaceSwitcher, edge: .below)
        }
    }

    /// "New workspace…" anchored on `view` (`rect` in it, or its bounds).
    func beginNewWorkspace(moving nodeIds: [UUID] = [], from view: NSView, rect: NSRect? = nil, edge: WorkspaceEditorEdge) {
        workspaceEditor.beginNew(moving: nodeIds, placement: anchoredPlacement(view, rect: rect, edge: edge))
    }

    private func anchoredPlacement(_ view: NSView, rect: NSRect?, edge: WorkspaceEditorEdge) -> () -> WorkspaceEditorController.Placement? {
        var last: WorkspaceEditorController.Placement?
        return { [weak view] in
            if let view, let window = view.window, window.isVisible || last == nil {
                let anchor = window.convertToScreen(view.convert(rect ?? view.bounds, to: nil))
                let parent = (window as? FlyoutPanel)?.parent ?? window
                last = WorkspaceEditorController.placement(anchor: anchor, parent: parent, edge: edge)
            }
            return last
        }
    }

    /// ⌘N, the title "+" menu, the rail's "+" dot and a swipe past the last page.
    func promptCreateWorkspace() {
        beginNewWorkspace()
    }

    // MARK: - App sheet (Settings in the rail)

    private func makeAppSheet() -> AppSheetFlyout {
        isAppSheetLoaded = true
        let sheet = AppSheetFlyout()
        sheet.onClose = { [weak self] in self?.updateRailGear() }
        return sheet
    }

    private var isAppSheetOpen: Bool { isAppSheetLoaded && appSheet.isOpen }

    /// The rail's gear: the app sheet beside the window, or closed again.
    func toggleAppSheet() {
        guard let window = view.window else { return }
        let gear = railView.settingsGear
        let anchor = window.convertToScreen(gear.convert(gear.bounds, to: nil))
        appSheet.toggle(anchor: anchor, edge: .beside(column: window.frame), topInset: 22, parent: window,
                        colorId: model.currentWorkspace.colorId)
        updateRailGear()
    }

    func updateRailGear() {
        railView.setSettings(open: isAppSheetOpen, badge: AppSheet.showsBadge(needs: AppPreferences.shared.permissionNeeds))
    }

    /// A click elsewhere in the window closes the workspace editor and the rail's sheet
    /// (their panels see clicks in their own host window as their host's).
    private func installHostClickMonitor() {
        hostClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            let hit = window.contentView?.hitTest(window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero)
            if self.isAppSheetOpen, hit.map({ !$0.isDescendant(of: self.railView.settingsGear) }) ?? true {
                self.appSheet.close()
            }
            if event.type == .leftMouseDown, self.workspaceEditor.isOpen { self.workspaceEditor.close() }
            return event
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

    /// Adds the folder, then names it in a flyout beside its cell. Cancelling takes an
    /// empty new folder away again; one that was given items keeps the default name.
    private func createFolderInRail(parentId: UUID?, moving nodeIds: [UUID] = []) {
        if let parentId { model.setFolderExpanded(id: parentId, isExpanded: true) }
        let id = model.addFolder(name: NodeDefaults.folderName, parentId: parentId)
        for nodeId in nodeIds.reversed() { model.moveNode(id: nodeId, toParentId: id, index: 0) }
        rail.reloadRail()
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
    func createTaskInRail(parentId: UUID?) {
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

    func clearSearch() {
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
        pasteButton.isHidden = rail
        updateTitleAddVisibility()
        if isAppSheetOpen { appSheet.close() }
        // The rail has no Settings page; narrowing from it returns to the workspace.
        if rail, model.state.isSettingsSelected {
            model.selectWorkspace(id: model.activeWorkspaceId)
            pageController.jumpToPage(currentPageIndex())
        }
        updateFooterFit()
        nodeListViewController.elasticMode = mode
        updateSettingsConstraints()
        self.rail.updateRailVisibility()
        self.rail.reloadRail()
    }

    /// Open dots need the browsers' tab lists, read by OpenTabsMonitor only while a workspace
    /// with items (rail, list, sidebar or mosaic) is on a visible window.
    func updateOpenTabsPolling() {
        let wanted = !model.state.isSettingsSelected
            && view.window?.occlusionState.contains(.visible) == true
            && model.activeWorkspace.items.contains(where: { !$0.isArchived })
        openTabs.setDemand(.list, wanted)
    }

    @objc private func windowOcclusionChanged(_ note: Notification) {
        updateOpenTabsPolling()
    }

    func selectWorkspaceAndPage(_ id: UUID) {
        guard let idx = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
        model.selectWorkspace(id: id)
        pageController.jumpToPage(idx + 1)
    }

    /// Settings: the page at list width and wider, the gear's app sheet in the rail.
    func enterSettings() {
        if elasticMode == .rail {
            if !isAppSheetOpen { toggleAppSheet() }
            return
        }
        model.selectSettings()
        pageController.jumpToPage(0)
    }

    /// Back to the workspace you were on before Settings.
    func leaveSettings() {
        guard model.state.isSettingsSelected else { return }
        selectWorkspaceAndPage(model.activeWorkspaceId)
    }

    /// ⌘, and the title gear open Settings and close it again: the page, or the rail's sheet.
    func toggleSettings() {
        if elasticMode == .rail {
            toggleAppSheet()
        } else if model.state.isSettingsSelected {
            leaveSettings()
        } else {
            enterSettings()
        }
    }

    /// Esc on the window: closes the rail's sheet, or leaves the Settings page.
    func handleEscape() -> Bool {
        if isAppSheetOpen {
            appSheet.close()
            return true
        }
        if model.state.isSettingsSelected, elasticMode != .rail {
            leaveSettings()
            return true
        }
        return false
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
        guard bottomBar != nil, !contentStack.isHidden else { return }
        // The bar spans the content stack, inset by the window padding. Its own bounds still
        // hold the previous width here: viewDidLayout runs before the stack lays it out.
        let width = view.bounds.width - 2 * LayoutConstants.windowPadding
        guard width > 0 else { return }
        // Measured without changing what the buttons show; toggling them here to re-measure
        // would invalidate layout from inside viewDidLayout and loop.
        let fit = FooterButton.footerFit(width: width, stowFull: stowTabButton.fittingWidth(.full),
                                         stowTitle: stowTabButton.fittingWidth(.noKeycap), paste: pasteButton.fittingWidth(.noKeycap))
        if stowTabButton.fit != fit { stowTabButton.fit = fit }
        let pasteFit: FooterButton.Fit = fit == .icon ? .icon : .noKeycap
        if pasteButton.fit != pasteFit { pasteButton.fit = pasteFit }
    }

    private var bottomBar: NSView?

    /// ⌥⌘S from any app (AppDelegate): stows the front browser tab.
    func stowFrontTab() {
        links.stowFrontTab()
    }

    func updateSettingsConstraints() {
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
        toggleSettings()
    }

    /// The title "+" (New…) adds to the workspace on show, so Settings and the rail hide it.
    private func updateTitleAddVisibility() {
        titleAddButton.isHidden = elasticMode == .rail || model.state.isSettingsSelected
    }

    /// Ink for the title-row buttons; Settings wears the selected pill on its page.
    private func updateTitleButtons(colors: StowTheme.Colors) {
        let onSettings = model.state.isSettingsSelected
        updateTitleAddVisibility()
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
    func addDroppedText(_ text: String, parentId: UUID?, index: Int) {
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
                links.fetchTitleForNewLink(id: id, url: url)
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

    @objc private func handleFaviconUpdate(_ notification: Notification) {
        guard let linkId = notification.userInfo?["linkId"] as? UUID,
              let path = notification.userInfo?["path"] as? String else { return }
        model.updateLinkFaviconPath(id: linkId, path: path)
    }

    // MARK: - Task & Snippet Actions

    func copySnippetToClipboard(_ snippetId: UUID) {
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
        keyboard.endCommandHold()
    }

    private var hasFocusedListOnFirstKey = false

    @objc private func windowDidFirstBecomeKey(_ note: Notification) {
        guard !hasFocusedListOnFirstKey else { return }
        hasFocusedListOnFirstKey = true
        view.window?.makeFirstResponder(nodeListViewController.focusTarget)
    }

    /// Jump letters, ⌘-hold and / act on the list, which the rail hides.
    var acceptsListShortcuts: Bool { elasticMode != .rail }

    /// Whether the title-bar strip is renaming a workspace.
    var isWorkspaceStripRenaming: Bool { workspaceSwitcher.isInlineRenaming }

    /// The first page a swipe reaches: 1 in the rail, which has no Settings page.
    var firstSwipePage: Int { pageController.firstPage }

    /// The page the pager shows now.
    var shownPage: Int { Int(pageSwipe.shownOffset.rounded()) }

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

    /// ⌘J (AppDelegate).
    func toggleJumpMode() {
        keyboard.toggleJumpMode()
    }

    /// Switches to workspace at the given index (0-based). Called from AppDelegate Cmd+1-9.
    func switchToWorkspace(atIndex index: Int) {
        guard index >= 0, index < model.workspaces.count else { return }
        let workspace = model.workspaces[index]
        model.selectWorkspace(id: workspace.id)
        pageController.jumpToPage(index + 1)
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
