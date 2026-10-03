import AppKit
import ObjectiveC

nonisolated(unsafe) private var taskIdKey: UInt8 = 0
nonisolated(unsafe) private var panelKey: UInt8 = 0

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
    /// In rail mode the strip collapses to one chip for the current workspace.
    private let railWorkspaceChip = NSButton()
    private let railView = RailView()
    private var railOpenTimer: Timer?
    private var elasticMode: ElasticMode = .sidebar
    /// The Settings page's own width (~240pt) would stop the window narrowing to a rail,
    /// so its constraints are switched off whenever Settings isn't showing.
    private var settingsConstraints: [NSLayoutConstraint] {
        view.constraints.filter { ($0.firstItem as? NSView) === settingsViewController.view || ($0.secondItem as? NSView) === settingsViewController.view }
    }
    private let titleAddButton = NSButton()
    private let searchField = SearchBarView(style: .defaultSearch)
    private let newButton = IconTitleButton(title: "New", symbolName: "plus", style: .toolbar)
    private let pasteButton = IconTitleButton(title: "Paste", symbolName: "doc.on.clipboard", style: .toolbar)

    // Page navigation
    private let pageController = ScrollWheelPageController()
    private var topBar = NSView()

    // Content containers (show/hide for page switching)
    private let contentStack = NSStackView()

    // Swipe state
    private var isSwiping = false
    private var lastAddNewHapticTime: TimeInterval = 0
    private var outgoingSnapshotView: NSImageView?
    private var swipeStartPageIndex: Int = 0
    private var preloadedPageIndex: Int?
    private var swipeDirection: Int = 0 // -1 backward, 0 none, +1 forward

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
    private var customColorWorkspaceId: UUID?
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
        let view = NSView()
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
        tabline.provider = { [weak self] in
            guard let self else { return nil }
            let ws = self.model.currentWorkspace
            return TablineContent(workspaceId: ws.id, name: ws.name, colorId: ws.colorId, nodes: ws.items,
                                  workspaces: self.model.workspaces.map { .init(id: $0.id, name: $0.name, colorId: $0.colorId) })
        }
        tabline.onOpenLink = { [weak self] link in self?.openLink(link) }
        tabline.onSelectWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        tabline.onStowURL = { [weak self] url, title in
            guard let self else { return }
            let id = self.model.addLink(urlString: url.absoluteString, title: title, parentId: nil)
            self.fetchTitleForNewLink(id: id, url: url)
        }
        tabline.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        tabline.startIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(tintModeChanged), name: .stowTintModeChanged, object: nil)
        nodeListViewController.tintMode = StowTheme.preferredTint

        // Listen for favicon updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdate),
            name: .init("UpdateLinkFavicon"),
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
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePageWidth()
        applyElasticMode(ElasticMode.forWidth(view.bounds.width))
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
        workspaceSwitcher.onWorkspaceRightClick = { [weak self] workspaceId, point in
            self?.showWorkspaceContextMenu(for: workspaceId, at: point)
        }
        workspaceSwitcher.onWorkspaceReorder = { [weak self] workspaceId, index in
            self?.model.reorderWorkspace(id: workspaceId, toIndex: index)
        }
        for (button, symbol, label, action) in [
            (titleSettingsButton, "gearshape", "Settings", #selector(titleSettingsTapped)),
            (titleAddButton, "plus", "New Workspace", #selector(titleAddTapped)),
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
        titleAddButton.toolTip = "New Workspace (⌘N)"
        workspaceSwitcher.onWorkspaceRename = { [weak self] workspaceId, newName in
            self?.model.renameWorkspace(id: workspaceId, newName: newName)
        }


        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search…"
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

        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.target = self
        newButton.action = #selector(showNewItemMenu)
        newButton.toolTip = "New folder, task, snippet or workspace"

        // Node list view
        nodeListViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Settings view
        settingsViewController.appModel = model
        settingsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        settingsViewController.view.isHidden = true

        // Build content stack (search + nodeList + paste)
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(newButton)
        bottomBar.addSubview(pasteButton)

        contentStack.orientation = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.alignment = .centerX
        contentStack.addArrangedSubview(searchField)
        contentStack.addArrangedSubview(nodeListViewController.view)
        contentStack.addArrangedSubview(bottomBar)

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
        wireRail()

        let pad = LayoutConstants.windowPadding

        NSLayoutConstraint.activate([
            newButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            newButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            newButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            pasteButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            pasteButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            searchField.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 2),
            searchField.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -2),

            bottomBar.heightAnchor.constraint(equalToConstant: pasteButton.style.height),

            workspaceSwitcher.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            workspaceSwitcher.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            workspaceSwitcher.topAnchor.constraint(equalTo: topBar.topAnchor),
            workspaceSwitcher.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
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
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),

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
            self?.model.archiveNode(id: nodeId)
        }

        nodeListViewController.onNodeUnarchived = { [weak self] nodeId in
            self?.model.unarchiveNode(id: nodeId)
        }

        nodeListViewController.onNodePermanentlyDeleted = { [weak self] nodeId in
            self?.model.permanentlyDeleteNode(id: nodeId)
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
            guard let self else { return }
            for nodeId in nodeIds {
                self.model.archiveNode(id: nodeId)
            }
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

        nodeListViewController.onNewSnippetRequested = { [weak self] parentId in
            self?.createSnippetAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onMoveToNewWorkspace = { [weak self] nodeIds in
            guard let self else { return }
            let workspaceId = self.model.createWorkspace(name: "Untitled")
            for nodeId in nodeIds {
                self.model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
            }
            if let idx = self.model.workspaces.firstIndex(where: { $0.id == workspaceId }) {
                self.pageController.jumpToPage(idx + 1)
            }
            self.scheduleWorkspaceInlineRename(for: workspaceId)
        }

        nodeListViewController.onMoveToNewFolder = { [weak self] nodeIds in
            guard let self, !nodeIds.isEmpty else { return }
            let folderId = self.model.addFolder(name: "Untitled", parentId: nil)
            for nodeId in nodeIds {
                self.model.moveNode(id: nodeId, toParentId: folderId, index: 0)
            }
            self.nodeListViewController.scheduleInlineRename(for: folderId)
        }
    }

    private func bindModel() {
        model.onChange = { [weak self] in
            guard let self else { return }
            if self.isReloadScheduled { return }
            self.isReloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReloadScheduled = false
                self.reloadData()
            }
            CloudSyncManager.shared.scheduleLocalChanges()
        }
    }

    // MARK: - Data Reload

    private func reloadData() {
        if isSwiping { return }

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
        } else {
            showWorkspaceContent()
            applyBackgroundColor(for: model.currentWorkspace.colorId)
            DockIconRenderer.apply(model.currentWorkspace.colorId)
            nodeListViewController.workspaceColor = model.currentWorkspace.colorId
            let workspace = model.currentWorkspace
            let forceExpand = searchCoordinator.isSearchActive
            nodeListViewController.isSearchActive = searchCoordinator.isSearchActive

            // Partition items into active and archived
            let activeItems = workspace.items.filter { !$0.isArchived }
            let archivedItems = workspace.items.filter { $0.isArchived }
            let filteredNodes = searchCoordinator.filter(nodes: activeItems)
            let isSearching = searchCoordinator.isSearchActive
            let archivedMatches = isSearching ? searchCoordinator.filter(nodes: archivedItems, includeArchived: true) : []
            let activeCount = Self.leafCount(activeItems)
            let archivedMatchCount = Self.leafCount(archivedMatches)
            var summary = "\(Self.leafCount(filteredNodes)) of \(activeCount)"
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
                archivedCount: Self.leafCount(archivedItems),
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
            TablineController.shared.reload()
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
        let colors = StowTheme.colors(for: colorId, tint: StowTheme.preferredTint)
        searchField.colors = colors
        updateTitleButtons(colors: colors)
        updateSettingsConstraints()
        updateRailChip()
        pasteButton.colors = colors
        newButton.colors = colors
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
            pageController.pageWidth = width
        }
    }

    // MARK: - Content Show/Hide

    private func showSettingsContent() {
        contentStack.isHidden = true
        settingsViewController.view.isHidden = false
        updateRailVisibility()
    }

    private func showWorkspaceContent() {
        settingsViewController.view.isHidden = true
        contentStack.isHidden = false
        updateRailVisibility()
    }

    // MARK: - Workspace Management

    private func showWorkspaceContextMenu(for workspaceId: UUID, at point: NSPoint) {
        // Temporarily select the workspace for context menu actions
        let previousWorkspaceId = model.currentWorkspace.id
        if previousWorkspaceId != workspaceId {
            model.selectWorkspace(id: workspaceId)
        }

        let menu = NSMenu()
        let canDelete = model.workspaces.count > 1
        guard let workspaceIndex = model.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let canMoveLeft = workspaceIndex > 0
        let canMoveRight = workspaceIndex < model.workspaces.count - 1

        let renameItem = NSMenuItem(title: "Rename workspace…", action: #selector(renameWorkspaceFromMenu), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        let colorItem = NSMenuItem(title: "Change color", action: nil, keyEquivalent: "")
        colorItem.submenu = ContextMenuBuilder.workspaceColorSubmenu(
            currentColorId: model.currentWorkspace.colorId,
            target: self,
            colorAction: #selector(changeColorTo(_:)),
            customColorAction: #selector(chooseCustomColor)
        )
        menu.addItem(colorItem)

        if canMoveLeft || canMoveRight {
            menu.addItem(NSMenuItem.separator())

            if canMoveLeft {
                let moveLeftItem = NSMenuItem(title: "Move left", action: #selector(moveWorkspaceLeft), keyEquivalent: "")
                moveLeftItem.target = self
                menu.addItem(moveLeftItem)
            }

            if canMoveRight {
                let moveRightItem = NSMenuItem(title: "Move right", action: #selector(moveWorkspaceRight), keyEquivalent: "")
                moveRightItem.target = self
                menu.addItem(moveRightItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let shareItem = NSMenuItem(title: "Share workspace…", action: #selector(shareWorkspaceFromMenu), keyEquivalent: "")
        shareItem.target = self
        menu.addItem(shareItem)

        let exportItem = NSMenuItem(title: "Export workspace…", action: #selector(exportWorkspaceFromMenu), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        let importItem = NSMenuItem(title: "Import workspace…", action: #selector(importWorkspaceFromMenu), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: "Delete workspace…", action: #selector(deleteWorkspaceFromMenu), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = canDelete
        menu.addItem(deleteItem)

        if view.window != nil {
            let pointInView = view.convert(point, from: nil)
            menu.popUp(positioning: nil, at: pointInView, in: view)
        }
    }

    @objc private func renameWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        workspaceSwitcher.beginInlineRename(workspaceId: workspace.id)
    }

    @objc private func changeColorTo(_ sender: NSMenuItem) {
        guard let colorId = sender.representedObject as? WorkspaceColorId else { return }
        let workspace = model.currentWorkspace
        model.updateWorkspaceColor(id: workspace.id, colorId: colorId)
    }

    @objc private func chooseCustomColor() {
        customColorWorkspaceId = model.currentWorkspace.id
        let colorPanel = NSColorPanel.shared
        colorPanel.color = model.currentWorkspace.colorId.color
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(customColorChanged(_:)))
        colorPanel.isContinuous = true
        colorPanel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: Any?) {
        guard let workspaceId = customColorWorkspaceId else { return }
        let hex = NSColorPanel.shared.color.hexString
        model.updateWorkspaceColor(id: workspaceId, colorId: .custom(hex))
    }

    @objc private func shareWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        do {
            let url = try model.shareWorkspace(id: workspace.id)
            showSharePanel(url: url, workspaceName: workspace.name)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Share failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func showSharePanel(url: String, workspaceName: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Share \"\(workspaceName)\""
        panel.isFloatingPanel = true
        panel.contentMinSize = NSSize(width: 420, height: 160)
        panel.contentMaxSize = NSSize(width: 420, height: 200)

        let contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let label = NSTextField(labelWithString: "Anyone with this link can view and import your workspace:")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2

        let textField = NSTextField(string: url)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isEditable = false
        textField.isSelectable = true
        textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.cell?.usesSingleLineMode = true
        textField.cell?.isScrollable = false
        textField.cell?.truncatesLastVisibleLine = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copyButton = NSButton(title: "Copy link", target: nil, action: nil)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"

        contentView.addSubview(label)
        contentView.addSubview(textField)
        contentView.addSubview(copyButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            textField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            copyButton.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 16),
            copyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            copyButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])

        panel.contentView = contentView

        // Store URL for copy action
        let urlToCopy = url
        let panelRef = panel
        copyButton.target = self
        copyButton.action = #selector(copyShareLink(_:))
        objc_setAssociatedObject(copyButton, &panelKey, panelRef, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(copyButton, &taskIdKey, urlToCopy as NSString, .OBJC_ASSOCIATION_RETAIN)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func copyShareLink(_ sender: NSButton) {
        guard let urlString = objc_getAssociatedObject(sender, &taskIdKey) as? NSString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString as String, forType: .string)

        // Update button title briefly to confirm
        sender.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sender.title = "Copy link"
        }
    }

    @objc private func exportWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "stow")!]
        savePanel.nameFieldStringValue = "\(workspace.name).stow"
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        do {
            let data = try model.exportWorkspace(id: workspace.id)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func importWorkspaceFromMenu() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.init(filenameExtension: "stow")!]
        openPanel.allowsMultipleSelection = false

        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try model.importWorkspace(from: data)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func deleteWorkspaceFromMenu() {
        let workspace = model.currentWorkspace
        if workspace.items.isEmpty {
            model.deleteWorkspace(id: workspace.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete workspace?"
        alert.informativeText = "This will permanently delete the workspace and all its contents."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        if let deleteButton = alert.buttons.last {
            deleteButton.hasDestructiveAction = true
        }
        if alert.runModal() == .alertSecondButtonReturn {
            model.deleteWorkspace(id: workspace.id)
        }
    }

    @objc private func moveWorkspaceLeft() {
        let workspace = model.currentWorkspace
        model.moveWorkspace(id: workspace.id, direction: .left)
    }

    @objc private func moveWorkspaceRight() {
        let workspace = model.currentWorkspace
        model.moveWorkspace(id: workspace.id, direction: .right)
    }

    func promptCreateWorkspace() {
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

    func createTaskAndBeginRename(parentId: UUID?) {
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
        let newId = model.addSnippet(title: "Untitled", content: "", language: nil, parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    func createFolderAndBeginRename(parentId: UUID?) {
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addFolder(name: "Untitled", parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
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
        let menu = NSMenu()
        let paste = NSMenuItem(title: "Paste", action: #selector(importClipboardContent), keyEquivalent: "v")
        paste.target = self
        paste.isEnabled = isPasteAvailable
        menu.addItem(paste)
        let arc = NSMenuItem(title: "Import from Arc…", action: #selector(importFromArcFromEmptyState), keyEquivalent: "")
        arc.target = self
        menu.addItem(arc)
        menu.addItem(.separator())
        for (title, action) in [("New Folder", #selector(menuNewFolder)), ("New Task", #selector(menuNewTask)), ("New Snippet", #selector(menuNewSnippet))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func importFromArcFromEmptyState() {
        settingsViewController.importFromArc()
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
        guard mode != elasticMode || railWorkspaceChip.superview == nil else { return }
        elasticMode = mode
        if railWorkspaceChip.superview == nil {
            railWorkspaceChip.translatesAutoresizingMaskIntoConstraints = false
            railWorkspaceChip.isBordered = false
            railWorkspaceChip.wantsLayer = true
            railWorkspaceChip.layer?.cornerRadius = 8
            railWorkspaceChip.target = self
            railWorkspaceChip.action = #selector(railChipTapped)
            railWorkspaceChip.setAccessibilityLabel("Workspaces")
            topBar.addSubview(railWorkspaceChip)
            NSLayoutConstraint.activate([
                railWorkspaceChip.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
                railWorkspaceChip.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
                railWorkspaceChip.widthAnchor.constraint(equalToConstant: 34),
                railWorkspaceChip.heightAnchor.constraint(equalToConstant: 24),
            ])
        }
        let rail = mode == .rail
        workspaceSwitcher.isHidden = rail
        railWorkspaceChip.isHidden = !rail
        searchField.isHidden = rail
        titleSettingsButton.isHidden = rail
        titleAddButton.isHidden = rail
        newButton.titleText = rail ? "" : "New"
        pasteButton.isHidden = rail
        nodeListViewController.elasticMode = mode
        updateSettingsConstraints()
        updateRailChip()
        updateRailVisibility()
        reloadRail()
    }

    // MARK: - Rail

    /// The rail replaces the workspace chrome (header, search, list, bottom bar) and, like
    /// the mockup, drops the traffic lights. Settings keeps its own header in rail.
    private func updateRailVisibility() {
        let showRail = elasticMode == .rail && !model.state.isSettingsSelected
        railView.isHidden = !showRail
        topBar.isHidden = showRail
        if showRail {
            contentStack.isHidden = true
        } else if !model.state.isSettingsSelected {
            contentStack.isHidden = false
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            view.window?.standardWindowButton(kind)?.isHidden = showRail
        }
        if showRail, railOpenTimer == nil {
            railOpenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRailOpenTabs() }
            }
            refreshRailOpenTabs()
        } else if !showRail {
            railOpenTimer?.invalidate()
            railOpenTimer = nil
        }
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
        for link in ws.items.flattenLinks() where link.faviconPath == nil {
            guard let url = URL(string: link.url) else { continue }
            FaviconService.shared.favicon(for: url, cachedPath: nil) { _, path in
                guard let path else { return }
                NotificationCenter.default.post(name: .init("UpdateLinkFavicon"), object: nil, userInfo: ["linkId": link.id, "path": path])
            }
        }
    }

    private func refreshRailOpenTabs() {
        Task.detached(priority: .utility) { [weak self] in
            let keys = Set(await BrowserTabService.tabsByCanonicalURL().keys)
            await MainActor.run { self?.railView.setOpenKeys(keys) }
        }
    }

    private func selectWorkspaceAndPage(_ id: UUID) {
        guard let idx = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
        model.selectWorkspace(id: id)
        pageController.jumpToPage(idx + 1)
    }

    private func wireRail() {
        railView.onSelectWorkspace = { [weak self] id in self?.selectWorkspaceAndPage(id) }
        railView.onWorkspaceMenu = { [weak self] anchor in self?.showRailWorkspaceMenu(from: anchor) }
        railView.onOpenLink = { [weak self] link in self?.openLink(link) }
        railView.onOpenFolder = { [weak self] folder in self?.openLinksInFolder(folder) }
        railView.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        railView.onCopySnippet = { [weak self] id in
            guard let self, case .snippet(let snippet)? = self.model.nodeById(id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet.content, forType: .string)
        }
        railView.onStowTab = { [weak self] in self?.stowFrontTab() }
    }

    /// Saves the front tab of the browser the user was last in to the current workspace.
    private func stowFrontTab() {
        guard let bundleId = ActiveBrowserTracker.shared.lastActiveBundleId else { NSSound.beep(); return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let tab = BrowserTabService.frontTab(bundleId: bundleId)
            await MainActor.run {
                guard let self, let tab else { NSSound.beep(); return }
                _ = self.model.addLink(urlString: tab.url.absoluteString, title: tab.title, parentId: nil)
            }
        }
    }

    private func updateSettingsConstraints() {
        // Only while Settings is on screen (or mid-swipe toward it) does its width matter.
        let needed = model.state.isSettingsSelected || isSwiping
        if needed {
            NSLayoutConstraint.activate(parkedSettingsConstraints)
            parkedSettingsConstraints = []
        } else if parkedSettingsConstraints.isEmpty {
            parkedSettingsConstraints = settingsConstraints
            NSLayoutConstraint.deactivate(parkedSettingsConstraints)
        }
    }

    private var parkedSettingsConstraints: [NSLayoutConstraint] = []

    private func updateRailChip() {
        guard elasticMode == .rail else { return }
        let ws = model.currentWorkspace
        let colors = StowTheme.colors(for: model.state.isSettingsSelected ? .settingsBackground : ws.colorId)
        var items = model.workspaces.map { WorkspaceStripLayout.Item(id: $0.id, name: $0.name) }
        WorkspaceStripLayout.assignMonograms(&items)
        let mono = model.state.isSettingsSelected ? "⚙︎" : (items.first { $0.id == ws.id }?.monogram ?? "")
        railWorkspaceChip.attributedTitle = NSAttributedString(string: mono, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: colors.surface,
        ])
        railWorkspaceChip.layer?.backgroundColor = view.resolvedCGColor(colors.inkPrimary)
        railWorkspaceChip.toolTip = model.state.isSettingsSelected ? "Settings" : ws.name
    }

    @objc private func railChipTapped() {
        showRailWorkspaceMenu(from: railWorkspaceChip)
    }

    private func showRailWorkspaceMenu(from anchor: NSView) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings", action: #selector(titleSettingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        for (i, ws) in model.workspaces.enumerated() {
            let item = NSMenuItem(title: ws.name, action: #selector(railPickWorkspace(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.representedObject = ws.id
            item.state = (!model.state.isSettingsSelected && ws.id == model.currentWorkspace.id) ? .on : .off
            item.image = WorkspaceBarView.dotImage(color: StowTheme.colors(for: ws.colorId).light.surface.platformColor)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "New Workspace…", action: #selector(titleAddTapped), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func railPickWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let idx = model.workspaces.firstIndex(where: { $0.id == id }) else { return }
        model.selectWorkspace(id: id)
        pageController.jumpToPage(idx + 1)
    }

    @objc private func titleSettingsTapped() {
        model.selectSettings()
        pageController.jumpToPage(0)
    }

    @objc private func titleAddTapped() {
        promptCreateWorkspace()
    }

    /// Ink for the title-row buttons; Settings wears the selected pill on its page.
    private func updateTitleButtons(colors: StowTheme.Colors) {
        let onSettings = model.state.isSettingsSelected
        titleSettingsButton.layer?.backgroundColor = view.resolvedCGColor(onSettings ? colors.inkPrimary : .clear)
        titleSettingsButton.contentTintColor = onSettings ? colors.surface : colors.inkPrimary
        titleAddButton.contentTintColor = colors.inkPrimary
    }

    @objc private func showNewItemMenu() {
        let menu = NSMenu()
        let entries: [(String, String, String, NSEvent.ModifierFlags, Selector)] = [
            ("New Folder", "folder", "N", [.command], #selector(menuNewFolder)),
            ("New Task", "circle", "", [], #selector(menuNewTask)),
            ("New Snippet", "chevron.left.forwardslash.chevron.right", "", [], #selector(menuNewSnippet)),
        ]
        for (title, symbol, key, mask, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let workspace = NSMenuItem(title: "New Workspace…", action: #selector(menuNewWorkspace), keyEquivalent: "n")
        workspace.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        workspace.target = self
        menu.addItem(workspace)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: newButton.bounds.height + 4), in: newButton)
    }

    @objc private func menuNewFolder() { createFolderAndBeginRename(parentId: nil) }
    @objc private func menuNewTask() { createTaskAndBeginRename(parentId: nil) }
    @objc private func menuNewSnippet() { createSnippetAndBeginRename(parentId: nil) }
    @objc private func menuNewWorkspace() { promptCreateWorkspace() }

    @objc private func importClipboardContent() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        importText(pasted)
    }

    /// Adds every link, task or snippet found in `text` to the current workspace.
    private func importText(_ text: String) {
        for item in ClipboardImportParser.parse(text) {
            switch item {
            case .task(let title, let isCompleted):
                let id = model.addTask(title: title, parentId: nil)
                if isCompleted { model.toggleTaskCompletion(id: id) }
            case .link(let url, let defaultTitle):
                let id = model.addLink(urlString: url.absoluteString, title: defaultTitle, parentId: nil)
                fetchTitleForNewLink(id: id, url: url)
            case .snippet(let title, let content):
                model.addSnippet(title: title, content: content, language: nil, parentId: nil)
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

    /// Opens in the browser the user is working in, switching to its existing tab for
    /// the site if there is one. Holding Option looks for the tab in every browser.
    private func openLink(_ link: Link) {
        guard let url = URL(string: link.url) else { return }
        let bundleId = BrowserManager.linkTargetBundleId()
        let profile = bundleId.flatMap { model.currentWorkspace.browserProfiles[$0] }
        let searchEveryBrowser = NSEvent.modifierFlags.contains(.option) || !BrowserManager.opensInActiveBrowser
        Task.detached(priority: .userInitiated) {
            if await BrowserTabService.focusIfOpen(url: url, onlyIn: searchEveryBrowser ? nil : bundleId) { return }
            await MainActor.run { BrowserManager.open(url: url, bundleId: bundleId, profile: profile) }
        }
    }

    private func openLinksInFolder(_ folder: Folder) {
        let links = collectLinks(in: folder)
        guard !links.isEmpty else { return }
        let bundleId = BrowserManager.linkTargetBundleId()
        let profile = bundleId.flatMap { model.currentWorkspace.browserProfiles[$0] }
        // One tabs snapshot covers every link — avoids 20 detached Tasks each
        // re-querying every running browser on bulk open.
        Task.detached(priority: .userInitiated) {
            let tabs = await BrowserTabService.tabsByCanonicalURL()
            for link in links {
                guard let url = URL(string: link.url) else { continue }
                let key = BrowserTabService.canonicalize(url)
                if let tab = tabs[key], tab.bundleId == bundleId || bundleId == nil, BrowserTabService.focus(tab: tab) { continue }
                await MainActor.run { BrowserManager.open(url: url, bundleId: bundleId, profile: profile) }
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

    private func showDatePickerForTask(_ taskId: UUID) {
        guard let node = model.nodeById(taskId), case .task(let task) = node,
              let anchor = nodeListViewController.rowAnchorView(for: taskId) else { return }
        let editor = DueDatePopoverController(dueDate: task.dueDate) { [weak self] date in
            self?.model.updateTaskDueDate(id: taskId, dueDate: date)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func showSnippetEditor(_ snippetId: UUID) {
        guard let node = model.nodeById(snippetId), case .snippet(let snippet) = node else { return }

        let editor = SnippetEditorView(snippet: snippet) { [weak self] updatedTitle, updatedContent, updatedLanguage in
            guard let self else { return }
            let trimmedTitle = updatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty && trimmedTitle != snippet.title {
                self.model.renameNode(id: snippetId, newName: trimmedTitle)
            }
            self.model.updateSnippetContent(id: snippetId, content: updatedContent)
            self.model.updateSnippetLanguage(id: snippetId, language: updatedLanguage)
            self.model.autoDeriveTitleIfNeeded(id: snippetId)
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = "Edit snippet: \(snippet.title)"
        panel.isFloatingPanel = true
        panel.contentView = editor
        panel.center()
        panel.makeKeyAndOrderFront(nil)
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
            guard commandHoldReveal == nil, !isCommandHoldJump,
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
        pasteButton.shortcutHint = visible ? "⌘V" : nil
        newButton.shortcutHint = visible ? "⇧⌘N" : nil
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

        if chars == "/" && flags.isEmpty {
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

    private static func leafCount(_ nodes: [Node]) -> Int {
        nodes.reduce(0) { total, node in
            if case .folder(let folder) = node { return total + leafCount(folder.children) }
            return total + 1
        }
    }

    @objc private func tintModeChanged() {
        nodeListViewController.tintMode = StowTheme.preferredTint
        workspaceSwitcher.workspaceColor = workspaceSwitcher.workspaceColor
        applyBackgroundColor(for: displayedColorId)
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        refreshPasteAvailability()
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

    func focusSearch() {
        guard !model.state.isSettingsSelected else { return }
        nodeListViewController.isJumpModeActive = false
        searchField.focus()
    }

    func toggleJumpMode() {
        guard !model.state.isSettingsSelected else { return }
        guard nodeListViewController.hasNodeRows else {
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

        if let snapshot = captureContentSnapshot() {
            outgoingSnapshotView = snapshot
            view.addSubview(snapshot)
        }
    }

    private func cleanupSwipeTransition() {
        outgoingSnapshotView?.removeFromSuperview()
        outgoingSnapshotView = nil
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
            promptCreateWorkspace()
            return
        } else {
            let workspaceIdx = pageIndex - 1
            if workspaceIdx < model.workspaces.count {
                model.selectWorkspace(id: model.workspaces[workspaceIdx].id)
            }
        }

        reloadData()
        applyBackgroundColor(for: colorForPage(pageIndex))
        isSwiping = false
    }

    func pagerPageCount() -> Int {
        totalPageCount()
    }

    func pagerCurrentPage() -> Int {
        currentPageIndex()
    }
}
