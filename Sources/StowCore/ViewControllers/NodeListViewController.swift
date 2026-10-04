//
//  NodeListViewController.swift
//  Stow
//

import AppKit

private let archiveHeaderUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFFF")!
private let linksHeaderUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFF1")!
private let tasksHeaderUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFF2")!
private let snippetsHeaderUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFF3")!
private let archivedNamespaceUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

/// Creates a deterministic UUID for an archived row by XOR-ing the node UUID with a fixed namespace.
/// This ensures the diff algorithm treats active vs archived rows as distinct entries.
private func archivedRowId(for nodeId: UUID) -> UUID {
    let nodeBytes = withUnsafeBytes(of: nodeId.uuid) { Array($0) }
    let nsBytes = withUnsafeBytes(of: archivedNamespaceUUID.uuid) { Array($0) }
    var result = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 { result[i] = nodeBytes[i] ^ nsBytes[i] }
    let u = (result[0], result[1], result[2], result[3],
             result[4], result[5], result[6], result[7],
             result[8], result[9], result[10], result[11],
             result[12], result[13], result[14], result[15])
    return UUID(uuid: u)
}

/// Manages the node list collection view, including drag-drop and context menus
@MainActor
final class NodeListViewController: NSViewController {

    // MARK: - Properties

    fileprivate let collectionView = ContextMenuCollectionView()
    let scrollView = NSScrollView()
    private let dropIndicator = DropIndicatorView()
    private let emptyStateView = EmptyStateView()
    private var listMetrics = ListMetrics()

    // Overscroll shadow views
    private let topShadowView = NSView()
    private let bottomShadowView = NSView()

    private var visibleRows: [NodeListRow] = [] {
        didSet { elasticLayout?.shapes = visibleRows.map(shape(for:)) }
    }
    private var elasticLayout: ElasticLayout? { collectionView.collectionViewLayout as? ElasticLayout }
    /// The last data handed to `reloadData`, so a width change can rebuild the rows.
    private var lastInput: ReloadInput?
    /// At list width, tasks and snippets fold into counted rows that expand in place.
    private var expandedListSections: Set<NodeSection> = []
    private var isDraggingItems = false
    private var pendingInsertedIds: Set<UUID> = []
    private let rowAnimationDuration: TimeInterval = 0.16
    /// Whether the system asks for reduced motion; replaceable in tests.
    var reduceMotion: () -> Bool = { RailMotion.reduceMotion }
    private let rowAnimationOffset: CGFloat = 10

    // Multi-selection support
    fileprivate var selectedNodeIds: Set<UUID> = []
    fileprivate var isBulkContextMenu = false

    // Inline rename support
    private weak var inlineRenameItem: NodeCollectionViewItem?
    /// The rename flyout, where an item can't edit its own title (a mosaic tile or group).
    private weak var renameFlyout: TextFieldFlyout?
    private var isFlyoutRename = false
    private var renameNodeId: UUID?
    /// The item being renamed, in its row or in the rename flyout. A flyout another one
    /// replaced no longer counts, so it can't hold up reloads and keys.
    var inlineRenameNodeId: UUID? {
        get { isFlyoutRename && !isRenameFlyoutOpen ? nil : renameNodeId }
        set { renameNodeId = newValue }
    }
    private var isRenameFlyoutOpen: Bool {
        guard let renameFlyout else { return false }
        return flyouts.isOpen(.text) && renameFlyout.window != nil
    }
    private var pendingInlineRenameId: UUID?
    private var suppressNextSelection = false

    // Archive header stable UUID (defined at file scope for nonisolated access)
    static let archiveHeaderId = archiveHeaderUUID

    // Callbacks
    var onNodeSelected: ((UUID) -> Void)?
    var onFolderToggled: ((UUID, Bool) -> Void)?
    var onNodeMoved: ((UUID, UUID?, Int) -> Void)?
    var onNodeDeleted: ((UUID) -> Void)?
    var onNodeRenamed: ((UUID, String) -> Void)?
    var onNodeMovedToWorkspace: ((UUID, UUID) -> Void)?
    var onBulkNodesMovedToWorkspace: (([UUID], UUID) -> Void)?
    var onBulkNodesGrouped: (([UUID], String) -> UUID?)?
    var onBulkNodesCopied: (([UUID]) -> Void)?
    var onBulkNodesDeleted: (([UUID]) -> Void)?
    var onNewFolderRequested: ((UUID?) -> Void)?
    var onTaskToggled: ((UUID) -> Void)?
    var onSnippetClicked: ((UUID) -> Void)?
    var onTaskDueDateRequested: ((UUID) -> Void)?
    var onTaskDueDateCleared: ((UUID) -> Void)?
    var onSnippetEditRequested: ((UUID) -> Void)?
    var onNewTaskRequested: ((UUID?) -> Void)?
    var onNewSnippetRequested: ((UUID?) -> Void)?
    var onLinkUrlEdited: ((UUID, String) -> Void)?
    var onOpenFolderLinks: ((UUID) -> Void)?
    /// A one-off "Open in ▸" from a link's menu.
    var onOpenLinkIn: ((Link, OpensIn) -> Void)?
    var onBulkOpenLinks: (([UUID]) -> Void)?
    var onMoveToNewWorkspace: (([UUID]) -> Void)?
    var onMoveToNewFolder: (([UUID]) -> Void)?
    var onNodeUnarchived: ((UUID) -> Void)?
    var onNodePermanentlyDeleted: ((UUID) -> Void)?
    var onArchiveToggled: ((Bool) -> Void)?
    var onNewWorkspaceRequested: (() -> Void)?
    /// Text dropped on the list: the text, the folder it lands in (nil at the top level)
    /// and its index there. The drag registration comes with G1.
    var onDropText: ((String, UUID?, Int) -> Void)?
    /// The right-click menu for an item (NodeMenu), built by the owner, which has the model.
    var nodeMenuProvider: ((Node) -> NSMenu?)?
    /// Rename, Edit URL and the owner's due date and snippet editors open here.
    var flyouts = ItemFlyouts()

    // Current workspace provider (for filtering "Move to" menu)
    var currentWorkspaceIdProvider: (() -> UUID?)?

    // Data provider closure
    var nodeProvider: (() -> [Node])?
    var workspacesProvider: (() -> [Workspace])?
    var findNodeById: ((UUID) -> Node?)?
    var findNodeLocation: ((UUID) -> NodeLocation?)?
    var findNodeInNodes: ((UUID, [Node]) -> Node?)?

    // State
    var isSearchActive: Bool = false
    var workspaceColor: WorkspaceColorId = .defaultColor() {
        didSet {
            guard workspaceColor != oldValue else { return }
            listMetrics.colors = StowTheme.colors(for: workspaceColor, tint: tintMode)
            dropIndicator.accentColor = listMetrics.colors.accent
            updateShadows()
            // Restyle in place: a reloadData here would race the row diff that
            // follows a workspace switch and desync the item count.
            reconfigureVisibleItems()
        }
    }
    /// Elastic density, set from the window width.
    var elasticMode: ElasticMode = .sidebar {
        didSet {
            guard elasticMode != oldValue else { return }
            listMetrics.mode = elasticMode
            elasticLayout?.mode = elasticMode
            elasticLayout?.rowHeight = listMetrics.rowHeight
            if let lastInput {
                visibleRows = buildRows(lastInput)
            } else {
                elasticLayout?.shapes = visibleRows.map(shape(for:))
            }
            collectionView.reloadData()
        }
    }

    /// Canonical URLs of tabs open in any browser, for the open dot beside links.
    var openKeys: Set<String> = [] {
        didSet {
            guard openKeys != oldValue else { return }
            reconfigureVisibleItems()
        }
    }

    var tintMode: StowTheme.TintMode = .full {
        didSet {
            guard tintMode != oldValue else { return }
            listMetrics.colors = StowTheme.colors(for: workspaceColor, tint: tintMode)
            updateShadows()
            // Restyle in place: a reloadData here would race the row diff that
            // follows a workspace switch and desync the item count.
            reconfigureVisibleItems()
        }
    }

    /// Letters assigned to rows in order while jump mode is on.
    var jumpLetters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")

    /// Rows that get jump letters: items, not section labels or mosaic group labels.
    private var jumpableIndices: [Int] {
        visibleRows.indices.filter { i in
            let row = visibleRows[i]
            guard case .regular = row.kind, let node = row.node else { return false }
            if elasticMode == .mosaic, case .folder = node { return false }
            return true
        }
    }

    private func jumpLetter(at item: Int) -> String? {
        guard let ordinal = jumpableIndices.firstIndex(of: item), ordinal < jumpLetters.count else { return nil }
        return String(jumpLetters[ordinal])
    }

    /// The row index a jump letter points at, if any.
    func rowIndex(forJumpLetter letter: Character) -> Int? {
        guard let ordinal = jumpLetters.firstIndex(of: letter) else { return nil }
        let indices = jumpableIndices
        return ordinal < indices.count ? indices[ordinal] : nil
    }

    /// While true, rows and tiles show a–z jump letters and plain letter keys activate them.
    var isJumpModeActive = false {
        didSet {
            guard isJumpModeActive != oldValue else { return }
            for item in collectionView.visibleItems() {
                guard let nodeItem = item as? NodeItemConfigurable,
                      let indexPath = collectionView.indexPath(for: item),
                      let row = row(at: indexPath) else { continue }
                var isArchived = false
                if case .archived = row.kind { isArchived = true }
                let letter: String? = isJumpModeActive && !isArchived ? jumpLetter(at: indexPath.item) : nil
                nodeItem.setHintCharacter(letter)
            }
        }
    }

    /// The view that holds keyboard focus when the list is active.
    var focusTarget: NSView { collectionView }

    // MARK: - Initialization

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func loadView() {
        let view = NSView()
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupScrollView()
        setupEmptyState()
        setupShadowViews()
        setupNotifications()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateShadows()
    }

    // MARK: - Setup

    private func setupCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        collectionView.autoresizingMask = [.width, .height]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.wantsLayer = true
        collectionView.backgroundColors = [.clear]
        let layout = ElasticLayout()
        layout.mode = listMetrics.mode
        layout.rowHeight = listMetrics.rowHeight
        collectionView.collectionViewLayout = layout
        collectionView.register(SectionHeaderItem.self, forItemWithIdentifier: SectionHeaderItem.identifier)
        collectionView.register(NodeCollectionViewItem.self, forItemWithIdentifier: NodeCollectionViewItem.identifier)
        collectionView.register(NodeTileItem.self, forItemWithIdentifier: NodeTileItem.identifier)
        collectionView.register(ArchiveHeaderItem.self, forItemWithIdentifier: ArchiveHeaderItem.identifier)
        // Items reorder; links and text dragged in from a browser or editor are added.
        collectionView.registerForDraggedTypes([nodePasteboardType, .URL, .string])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        collectionView.onDragExit = { [weak self] in
            self?.hideDropIndicator()
        }
        collectionView.onBackgroundClick = { [weak self] in
            self?.clearSelections()
        }
        collectionView.parentViewController = self

        dropIndicator.isHidden = true
        collectionView.addSubview(dropIndicator)
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        collectionView.frame = scrollView.bounds
        scrollView.contentView.postsBoundsChangedNotifications = true

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupEmptyState() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The empty-state view, for wiring its actions and drop handling.
    var emptyStateOverlay: EmptyStateView { emptyStateView }

    private var isDismissingEmptyState = false

    /// Shows the empty state over the list, or hides it when `copy` is nil.
    func showEmptyState(_ copy: EmptyStateCopy?, workspaceName: String, animated: Bool) {
        if let copy {
            isDismissingEmptyState = false
            emptyStateView.colors = listMetrics.colors
            emptyStateView.show(copy, workspaceName: workspaceName, animated: animated)
            emptyStateView.isHidden = false
        } else if !emptyStateView.isHidden && !isDismissingEmptyState {
            emptyStateView.isHidden = true
            emptyStateView.reset()
        }
    }

    /// Plays the first-item moment on the visible empty state, then hides it.
    func dismissEmptyStateWithLanding() {
        guard !emptyStateView.isHidden, !isDismissingEmptyState else { return }
        isDismissingEmptyState = true
        emptyStateView.playLandingAndDismiss { [weak self] in
            guard let self, self.isDismissingEmptyState else { return }
            self.isDismissingEmptyState = false
            self.emptyStateView.isHidden = true
            self.emptyStateView.reset()
        }
    }

    var hasNodeRows: Bool { visibleRows.contains { $0.node != nil } }

    private func setupShadowViews() {
        let shadowHeight = ThemeConstants.Sizing.scrollShadowHeight

        topShadowView.translatesAutoresizingMaskIntoConstraints = false
        topShadowView.wantsLayer = true
        topShadowView.layer?.zPosition = 10
        view.addSubview(topShadowView)

        bottomShadowView.translatesAutoresizingMaskIntoConstraints = false
        bottomShadowView.wantsLayer = true
        bottomShadowView.layer?.zPosition = 10
        view.addSubview(bottomShadowView)

        NSLayoutConstraint.activate([
            topShadowView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            topShadowView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            topShadowView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            topShadowView.heightAnchor.constraint(equalToConstant: shadowHeight),

            bottomShadowView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            bottomShadowView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            bottomShadowView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bottomShadowView.heightAnchor.constraint(equalToConstant: shadowHeight),
        ])
    }

    func updateShadows() {
        let opaqueColor = view.resolvedCGColor(listMetrics.colors.surface)
        let clearColor = opaqueColor.copy(alpha: 0) ?? opaqueColor

        let clipView = scrollView.contentView
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = clipView.bounds.height
        let scrollY = clipView.bounds.origin.y

        let showTop = scrollY > 0.5
        let showBottom = (scrollY + visibleHeight) < (docHeight - 0.5)

        // Top shadow
        if let layer = topShadowView.layer {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            if showTop {
                let gradient = CAGradientLayer()
                gradient.frame = topShadowView.bounds
                gradient.colors = [opaqueColor, clearColor]
                gradient.startPoint = CGPoint(x: 0.5, y: 1) // flipped for AppKit
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                layer.addSublayer(gradient)
            }
        }

        // Bottom shadow
        if let layer = bottomShadowView.layer {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            if showBottom {
                let gradient = CAGradientLayer()
                gradient.frame = bottomShadowView.bounds
                gradient.colors = [clearColor, opaqueColor]
                gradient.startPoint = CGPoint(x: 0.5, y: 1) // flipped for AppKit
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                layer.addSublayer(gradient)
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    // MARK: - Public Methods

    /// Reloads the collection view with new visible rows
    func reloadData(with nodes: [Node], forceExpand: Bool, animated: Bool = true, archivedNodes: [Node] = [],
                    isArchiveExpanded: Bool = false, showArchiveDuringSearch: Bool = false) {
        let input = ReloadInput(nodes: nodes, forceExpand: forceExpand, archivedNodes: archivedNodes,
                                isArchiveExpanded: isArchiveExpanded, showArchiveDuringSearch: showArchiveDuringSearch)
        lastInput = input
        // A new task or snippet about to be renamed opens its folded section at list width.
        if let pending = pendingInlineRenameId, let node = nodes.first(where: { $0.id == pending }) {
            if case .task = node { expandedListSections.insert(.tasks) }
            if case .snippet = node { expandedListSections.insert(.snippets) }
        }
        let newRows = buildRows(input)

        if !animated {
            visibleRows = newRows
            collectionView.reloadData()
        } else {
            applyVisibleRows(newRows)
        }
        handlePendingInlineRename()
    }

    /// Links and folders first, then a Tasks section, then Snippets, then the archive.
    /// In the mosaic each folder becomes a labeled group of tiles and loose links get
    /// their own group. At list width tasks and snippets fold into counted rows.
    private func buildRows(_ input: ReloadInput) -> [NodeListRow] {
        let tree = input.nodes.filter { node in
            switch node { case .task, .snippet: return false; default: return true }
        }
        let tasks = input.nodes.filter { if case .task = $0 { return true }; return false }
        let snippets = input.nodes.filter { if case .snippet = $0 { return true }; return false }
        var rows: [NodeListRow] = []

        if elasticMode == .mosaic {
            let looseLinks = tree.filter { if case .link = $0 { return true }; return false }
            if !looseLinks.isEmpty {
                rows.append(NodeListRow(section: .links, meta: "\(looseLinks.count)", isExpanded: true))
                rows.append(contentsOf: looseLinks.map { NodeListRow(node: $0, depth: 0) })
            }
            for node in tree {
                if case .folder(let folder) = node { appendMosaicGroup(folder, path: [], into: &rows) }
            }
        } else {
            rows = buildVisibleRows(nodes: tree, depth: 0, forceExpand: input.forceExpand)
        }

        func appendSection(_ section: NodeSection, _ nodes: [Node], meta: String) {
            guard !nodes.isEmpty else { return }
            let expanded = elasticMode != .list || isSearchActive || expandedListSections.contains(section)
            rows.append(NodeListRow(section: section, meta: meta, isExpanded: expanded))
            if expanded {
                rows.append(contentsOf: nodes.map { NodeListRow(node: $0, depth: 0, section: section) })
            }
        }
        let openTasks = tasks.filter { if case .task(let t) = $0 { return !t.isCompleted }; return false }.count
        appendSection(.tasks, tasks, meta: "\(openTasks) open")
        appendSection(.snippets, snippets, meta: "\(snippets.count)")

        if !input.archivedNodes.isEmpty && (!isSearchActive || input.showArchiveDuringSearch) {
            rows.append(NodeListRow(archiveHeaderCount: input.archivedNodes.count, isExpanded: input.isArchiveExpanded))
            if input.isArchiveExpanded {
                rows.append(contentsOf: buildArchivedRows(nodes: input.archivedNodes, depth: 0))
            }
        }
        return rows
    }

    /// A folder's label, its items as tiles, then each subfolder as its own group.
    private func appendMosaicGroup(_ folder: Folder, path: [String], into rows: inout [NodeListRow]) {
        let fullPath = path + [folder.name]
        rows.append(NodeListRow(node: .folder(folder), depth: 0, groupTitle: fullPath.joined(separator: " › ")))
        for child in folder.children {
            if case .folder = child { continue }
            rows.append(NodeListRow(node: child, depth: 1))
        }
        for child in folder.children {
            if case .folder(let sub) = child { appendMosaicGroup(sub, path: fullPath, into: &rows) }
        }
    }

    private func shape(for row: NodeListRow) -> ElasticLayout.Shape {
        switch row.kind {
        case .sectionHeader: return .sectionHeader
        case .archiveHeader: return .row
        case .regular, .archived:
            guard elasticMode == .mosaic, let node = row.node else { return .row }
            switch node {
            case .folder:
                if case .regular = row.kind { return .groupHeader }
                return .linkTile
            case .link: return .linkTile
            case .task: return .taskTile
            case .snippet: return .snippetTile
            }
        }
    }

    /// Which cell class draws a row.
    private func itemIdentifier(for row: NodeListRow) -> NSUserInterfaceItemIdentifier {
        switch row.kind {
        case .archiveHeader: return ArchiveHeaderItem.identifier
        case .sectionHeader: return SectionHeaderItem.identifier
        case .regular, .archived:
            guard elasticMode == .mosaic else { return NodeCollectionViewItem.identifier }
            return shape(for: row) == .groupHeader ? SectionHeaderItem.identifier : NodeTileItem.identifier
        }
    }

    /// Section labels and mosaic group labels are passed over by the keyboard; the
    /// counted rows at list width can be focused and opened.
    private func isFocusable(_ row: NodeListRow) -> Bool {
        switch row.kind {
        case .sectionHeader: return elasticMode == .list
        case .archiveHeader, .archived: return true
        case .regular: return shape(for: row) != .groupHeader
        }
    }

    private func toggleListSection(_ section: NodeSection) {
        if expandedListSections.contains(section) {
            expandedListSections.remove(section)
        } else {
            expandedListSections.insert(section)
        }
        guard let lastInput else { return }
        applyVisibleRows(buildRows(lastInput))
    }

    /// Recursively builds rows for archived nodes, expanding folders that are marked expanded
    private func buildArchivedRows(nodes: [Node], depth: Int) -> [NodeListRow] {
        var rows: [NodeListRow] = []
        for node in nodes {
            rows.append(NodeListRow(node: node, depth: depth, kind: .archived))
            if case .folder(let folder) = node, folder.isExpanded {
                rows.append(contentsOf: buildArchivedRows(nodes: folder.children, depth: depth + 1))
            }
        }
        return rows
    }

    /// Clears all selections
    func clearSelections() {
        guard !selectedNodeIds.isEmpty else { return }
        selectedNodeIds.removeAll()
        reloadVisibleSelection()
    }

    /// Schedules inline rename for a node
    func scheduleInlineRename(for nodeId: UUID) {
        pendingInlineRenameId = nodeId
    }

    /// Cancels any in-progress inline rename
    func cancelInlineRename() {
        if let item = inlineRenameItem {
            item.cancelInlineRename()
        } else {
            if isRenameFlyoutOpen { flyouts.close(.text) }
            clearInlineRenameState()
        }
    }

    /// Returns the node at the given visible index, or nil if out of range
    func visibleNode(at index: Int) -> Node? {
        guard index >= 0, index < visibleRows.count else { return nil }
        return visibleRows[index].node
    }

    /// True for a row in the Archive section.
    func isArchivedRow(at index: Int) -> Bool {
        guard index >= 0, index < visibleRows.count, case .archived = visibleRows[index].kind else { return false }
        return true
    }

    /// Returns the number of regular (non-archive) rows
    var regularRowCount: Int {
        visibleRows.filter { if case .regular = $0.kind { return true }; return false }.count
    }

    /// Shows a checkmark symbol that floats up and fades out on the row for the given node ID
    func showCopiedFeedback(for nodeId: UUID) {
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) else { return }

        let symbol = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        symbol.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbol.contentTintColor = .white
        symbol.wantsLayer = true
        symbol.frame.size = NSSize(width: 20, height: 20)

        let rowView = item.view
        let startY = (rowView.bounds.height - symbol.frame.height) / 2
        symbol.frame.origin = NSPoint(
            x: rowView.bounds.maxX - symbol.frame.width - 14,
            y: startY
        )
        symbol.alphaValue = 0
        rowView.addSubview(symbol)

        // Fade in, then float up while fading out
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            symbol.animator().alphaValue = 1
        }, completionHandler: { [weak symbol] in
            MainActor.assumeIsolated {
                guard let symbol else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.6
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    symbol.animator().alphaValue = 0
                    symbol.animator().frame.origin.y = startY + 16
                }, completionHandler: { [weak symbol] in
                    MainActor.assumeIsolated {
                        symbol?.removeFromSuperview()
                    }
                })
            }
        })
    }

    // MARK: - Private Methods

    @objc private func handleScrollBoundsChanged() {
        for item in collectionView.visibleItems() {
            (item as? NodeCollectionViewItem)?.refreshHoverState()
        }
        updateShadows()
    }

    fileprivate func row(at indexPath: IndexPath) -> NodeListRow? {
        guard indexPath.item >= 0, indexPath.item < visibleRows.count else { return nil }
        return visibleRows[indexPath.item]
    }

    private func buildVisibleRows(nodes: [Node], depth: Int, forceExpand: Bool) -> [NodeListRow] {
        var rows: [NodeListRow] = []
        for node in nodes {
            rows.append(NodeListRow(node: node, depth: depth))
            if case .folder(let folder) = node, folder.isExpanded || forceExpand {
                rows.append(contentsOf: buildVisibleRows(nodes: folder.children, depth: depth + 1, forceExpand: forceExpand))
            }
        }
        return rows
    }

    private func applyVisibleRows(_ newRows: [NodeListRow]) {
        let animates = RailMotion.animates(windowVisible: collectionView.window != nil, swiping: false,
                                           reduceMotion: reduceMotion())
        if isSearchActive || !animates {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        let oldRows = visibleRows
        let oldIds = oldRows.map { $0.id }
        let newIds = newRows.map { $0.id }
        let oldSet = Set(oldIds)
        let newSet = Set(newIds)

        if oldSet == newSet {
            visibleRows = newRows
            if oldIds == newIds {
                reconfigureVisibleItems()
            } else {
                collectionView.reloadData()
            }
            return
        }

        var deletedIndexPaths: [IndexPath] = []
        for (index, row) in oldRows.enumerated() where !newSet.contains(row.id) {
            deletedIndexPaths.append(IndexPath(item: index, section: 0))
        }

        var insertedIndexPaths: [IndexPath] = []
        for (index, row) in newRows.enumerated() where !oldSet.contains(row.id) {
            insertedIndexPaths.append(IndexPath(item: index, section: 0))
        }

        // When rows move between sections (e.g. archive/unarchive), both deletions
        // and insertions occur simultaneously. Fall back to reloadData to avoid
        // stale cells that keep showing old content after position shifts.
        if !deletedIndexPaths.isEmpty && !insertedIndexPaths.isEmpty {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        let deletionSnapshots = makeDeletionSnapshots(for: deletedIndexPaths)

        performListUpdates(
            newRows: newRows,
            insertedIndexPaths: insertedIndexPaths,
            deletedIndexPaths: deletedIndexPaths
        )
        animateDeletionSnapshots(deletionSnapshots)
    }

    private func performListUpdates(newRows: [NodeListRow],
                                    insertedIndexPaths: [IndexPath],
                                    deletedIndexPaths: [IndexPath]) {
        pendingInsertedIds = Set(insertedIndexPaths.compactMap { indexPath in
            guard indexPath.item < newRows.count else { return nil }
            return newRows[indexPath.item].id
        })
        visibleRows = newRows
        collectionView.performBatchUpdates({
            if !deletedIndexPaths.isEmpty {
                collectionView.deleteItems(at: Set(deletedIndexPaths))
            }
            if !insertedIndexPaths.isEmpty {
                collectionView.insertItems(at: Set(insertedIndexPaths))
            }
        }, completionHandler: { [weak self] _ in
            self?.reconfigureVisibleItems()
        })
    }

    private func makeDeletionSnapshots(for indexPaths: [IndexPath]) -> [NSImageView] {
        var snapshots: [NSImageView] = []
        for indexPath in indexPaths {
            guard let item = collectionView.item(at: indexPath) else { continue }
            let view = item.view
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            let frame = view.convert(view.bounds, to: collectionView)
            let imageView = NSImageView(frame: frame)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            collectionView.addSubview(imageView)
            view.alphaValue = 0
            snapshots.append(imageView)
        }
        return snapshots
    }

    private func animateDeletionSnapshots(_ snapshots: [NSImageView]) {
        guard !snapshots.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = rowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            for snapshot in snapshots {
                let finalOrigin = NSPoint(x: snapshot.frame.origin.x, y: snapshot.frame.origin.y - rowAnimationOffset)
                snapshot.animator().setFrameOrigin(finalOrigin)
                snapshot.animator().alphaValue = 0
            }
        } completionHandler: {
            DispatchQueue.main.async {
                for snapshot in snapshots {
                    snapshot.removeFromSuperview()
                }
            }
        }
    }

    private func animateInsert(item: NSCollectionViewItem) {
        guard !reduceMotion() else { return }
        let view = item.view
        view.wantsLayer = true
        let finalOrigin = view.frame.origin
        view.alphaValue = 0
        view.frame.origin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - rowAnimationOffset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = rowAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            view.animator().setFrameOrigin(finalOrigin)
            view.animator().alphaValue = 1
        }
    }

    /// Starts the rename `scheduleInlineRename` asked for. A reload that can't show the
    /// item drops it, so a later reload never opens a rename out of nowhere.
    private func handlePendingInlineRename() {
        guard let nodeId = pendingInlineRenameId else { return }
        pendingInlineRenameId = nil
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }) else { return }
        let indexPath = IndexPath(item: index, section: 0)

        DispatchQueue.main.async { [weak self] in
            guard let self, index < self.visibleRows.count, self.visibleRows[index].id == nodeId else { return }
            self.collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
            self.collectionView.layoutSubtreeIfNeeded()
            self.beginInlineRename(nodeId: nodeId, indexPath: indexPath)
        }
    }

    /// Renames in place on a list row; on a mosaic tile or group header, which can't edit
    /// their own titles, in the rename flyout beside them. Returns that flyout.
    @discardableResult
    private func beginInlineRename(nodeId: UUID, indexPath: IndexPath) -> TextFieldFlyout? {
        cancelInlineRename()
        guard findNodeById?(nodeId) != nil else {
            clearInlineRenameState()
            return nil
        }
        guard let item = collectionView.item(at: indexPath) as? NodeCollectionViewItem else {
            return beginFlyoutRename(nodeId: nodeId)
        }

        inlineRenameNodeId = nodeId
        inlineRenameItem = item
        item.beginInlineRename(onCommit: { [weak self] newName in
            self?.commitInlineRename(newName)
        }, onCancel: { [weak self] in
            self?.handleInlineRenameCancelled()
        })
        return nil
    }

    private func beginFlyoutRename(nodeId: UUID) -> TextFieldFlyout? {
        let flyout = presentRenameFlyout(for: nodeId, onEnd: { [weak self] in
            guard let self, self.renameNodeId == nodeId else { return }
            self.clearInlineRenameState()
            self.refocusListAfterRename()
        })
        guard let flyout else {
            clearInlineRenameState()
            return nil
        }
        renameFlyout = flyout
        isFlyoutRename = true
        inlineRenameNodeId = nodeId
        return flyout
    }

    private func commitInlineRename(_ newName: String) {
        guard let nodeId = inlineRenameNodeId else {
            clearInlineRenameState()
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handleInlineRenameCancelled()
            return
        }
        onNodeRenamed?(nodeId, trimmed)
        clearInlineRenameState()
        refocusListAfterRename()
    }

    private func handleInlineRenameCancelled() {
        suppressNextSelection = true
        clearInlineRenameState()
        refocusListAfterRename()
    }

    /// Gives the list focus back once a rename ends, unless the rename ended because
    /// something else (search, another field) took focus.
    private func refocusListAfterRename() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window, self.inlineRenameNodeId == nil else { return }
            let responder = window.firstResponder
            let isFree = responder == nil || responder === window || responder === self.collectionView
                || (responder as? NSView)?.isDescendant(of: self.collectionView) == true
            if isFree { self.focusList() }
        }
    }

    private func clearInlineRenameState() {
        inlineRenameItem = nil
        renameFlyout = nil
        isFlyoutRename = false
        inlineRenameNodeId = nil
    }

    private func toggleSelection(for nodeId: UUID) {
        if selectedNodeIds.contains(nodeId) {
            selectedNodeIds.remove(nodeId)
        } else {
            selectedNodeIds.insert(nodeId)
        }
        reloadVisibleSelection()
    }

    private func reloadVisibleSelection() {
        for (index, _) in visibleRows.enumerated() {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.reloadItems(at: [indexPath])
        }
    }

    // MARK: - Keyboard

    /// The row the keyboard acts on. Drawn with a focus ring while the list has focus.
    private var keyboardCursorId: UUID? {
        didSet {
            guard keyboardCursorId != oldValue else { return }
            updateKeyboardCursorVisuals()
        }
    }

    /// Like CSS :focus-visible: the ring appears once the keyboard is used and hides on click.
    private var isKeyboardNavigating = false

    private var listHasFocus: Bool {
        isKeyboardNavigating && view.window?.isKeyWindow == true && view.window?.firstResponder === collectionView
    }

    func mouseInteractionOccurred() {
        guard isKeyboardNavigating else { return }
        isKeyboardNavigating = false
        updateKeyboardCursorVisuals()
    }

    /// Takes keyboard focus, e.g. when leaving search with Esc or the down arrow.
    func focusList() {
        view.window?.makeFirstResponder(collectionView)
        isKeyboardNavigating = true
        if keyboardCursorId == nil || cursorIndex == nil {
            keyboardCursorId = visibleRows.first(where: { $0.node != nil && isFocusable($0) })?.id
        }
        updateKeyboardCursorVisuals()
    }

    /// The on-screen row view for a node, for anchoring popovers.
    func rowAnchorView(for nodeId: UUID) -> NSView? {
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }) else { return nil }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        return collectionView.item(at: indexPath)?.view
    }

    func listFocusChanged() {
        if listHasFocus && keyboardCursorId == nil {
            keyboardCursorId = visibleRows.first(where: { $0.node != nil && isFocusable($0) })?.id
        }
        updateKeyboardCursorVisuals()
    }

    private func updateKeyboardCursorVisuals() {
        let showRing = listHasFocus
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item), let row = row(at: indexPath) else { continue }
            (item as? NodeItemConfigurable)?.setKeyboardFocused(showRing && row.id == keyboardCursorId)
        }
    }

    private var cursorIndex: Int? {
        guard let id = keyboardCursorId else { return nil }
        return visibleRows.firstIndex(where: { $0.id == id })
    }

    private func moveCursor(to index: Int) {
        guard !visibleRows.isEmpty else { return }
        var clamped = min(max(index, 0), visibleRows.count - 1)
        // Step past labels in the direction of travel, or back if there's nothing beyond.
        let forward = index >= (cursorIndex ?? -1)
        if !isFocusable(visibleRows[clamped]) {
            let ahead = forward ? Array(clamped..<visibleRows.count) : Array((0...clamped).reversed())
            let behind = forward ? Array((0...clamped).reversed()) : Array(clamped..<visibleRows.count)
            guard let target = (ahead + behind).first(where: { isFocusable(visibleRows[$0]) }) else { return }
            clamped = target
        }
        keyboardCursorId = visibleRows[clamped].id
        let indexPath = IndexPath(item: clamped, section: 0)
        collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
    }

    func activate(_ node: Node) {
        switch node {
        case .folder(let folder):
            onFolderToggled?(folder.id, !folder.isExpanded)
        case .link(let link):
            onNodeSelected?(link.id)
        case .task(let task):
            onTaskToggled?(task.id)
        case .snippet(let snippet):
            onSnippetClicked?(snippet.id)
        }
    }

    /// Handles a key pressed while the list has focus. Returns true when consumed.
    func handleListKey(_ event: NSEvent) -> Bool {
        guard inlineRenameNodeId == nil else { return false }
        // With nothing to navigate, Down and Tab move to the empty state's action.
        if !hasNodeRows, [125, 48].contains(event.keyCode), !emptyStateView.isHidden,
           emptyStateView.actionView.acceptsFirstResponder {
            view.window?.makeFirstResponder(emptyStateView.actionView)
            return true
        }
        if !isKeyboardNavigating {
            isKeyboardNavigating = true
            if keyboardCursorId == nil || cursorIndex == nil {
                keyboardCursorId = visibleRows.first(where: { $0.node != nil && isFocusable($0) })?.id
            }
            updateKeyboardCursorVisuals()
            // The first arrow press only reveals where the cursor is.
            if [125, 126].contains(event.keyCode) && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
                return true
            }
        }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let index = cursorIndex
        let row = index.flatMap { visibleRows.indices.contains($0) ? visibleRows[$0] : nil }

        // In the mosaic the arrows follow the grid. ←/→ fall through to collapse/expand
        // below when there's no tile beside the cursor.
        if elasticMode == .mosaic, flags.isEmpty, let index,
           let direction: ElasticLayout.Direction = [125: .down, 126: .up, 123: .left, 124: .right][event.keyCode] {
            if let target = mosaicNeighbor(of: index, direction: direction) {
                moveCursor(to: target)
                return true
            }
            if direction == .up || direction == .down { return true }
        }

        switch (event.keyCode, flags) {
        case (125, []): // down
            moveCursor(to: (index ?? -1) + 1)
        case (126, []): // up
            moveCursor(to: (index ?? visibleRows.count) - 1)
        case (115, []), (126, [.command]): // home, cmd-up
            moveCursor(to: 0)
        case (119, []), (125, [.command]): // end, cmd-down
            moveCursor(to: visibleRows.count - 1)

        case (123, []): // left: collapse, or go to parent
            guard let index, let row else { return true }
            if case .folder(let folder) = row.node, folder.isExpanded, !isSearchActive {
                onFolderToggled?(folder.id, false)
            } else if row.depth > 0,
                      let parent = visibleRows[..<index].lastIndex(where: { $0.depth == row.depth - 1 }) {
                moveCursor(to: parent)
            } else if case .archiveHeader(_, true) = row.kind {
                onArchiveToggled?(false)
            } else if case .sectionHeader(let section, _, true) = row.kind, elasticMode == .list {
                toggleListSection(section)
            }
        case (124, []): // right: expand, or go to first child
            guard let index, let row else { return true }
            if case .folder(let folder) = row.node, !isSearchActive {
                if !folder.isExpanded {
                    onFolderToggled?(folder.id, true)
                } else if index + 1 < visibleRows.count, visibleRows[index + 1].depth > row.depth {
                    moveCursor(to: index + 1)
                }
            } else if case .archiveHeader(_, false) = row.kind {
                onArchiveToggled?(true)
            } else if case .sectionHeader(let section, _, false) = row.kind, elasticMode == .list {
                toggleListSection(section)
            }

        case (36, []), (76, []): // return, enter
            guard let row else { return true }
            if case .archiveHeader(_, let isExpanded) = row.kind {
                onArchiveToggled?(!isExpanded)
            } else if case .sectionHeader(let section, _, _) = row.kind {
                if elasticMode == .list { toggleListSection(section) }
            } else if case .archived = row.kind {
                return true
            } else if let node = row.node {
                activate(node)
            }
        case (36, [.option]), (76, [.option]): // option-return: row actions menu
            guard let index, row?.node != nil else { return true }
            showContextMenu(forRowAt: index)
        case (120, []): // F2: rename
            guard let index, let node = row?.node, case .regular = row?.kind else { return true }
            beginInlineRename(nodeId: node.id, indexPath: IndexPath(item: index, section: 0))
        case (51, [.command]), (117, [.command]): // cmd-delete: archive
            guard let index, let node = row?.node, case .regular = row?.kind else { return true }
            onNodeDeleted?(node.id)
            clearSelections()
            // Keep the cursor in place on the row that slides up.
            DispatchQueue.main.async { [weak self] in self?.moveCursor(to: index) }
        case (49, [.option]): // option-space: add/remove from multi-selection
            guard let node = row?.node, case .regular = row?.kind else { return true }
            toggleSelection(for: node.id)
        case (53, []): // esc
            if !selectedNodeIds.isEmpty { clearSelections() } else { return false }
        default:
            return false
        }
        return true
    }

    private func mosaicNeighbor(of index: Int, direction: ElasticLayout.Direction) -> Int? {
        let frames = visibleRows.indices.map { frameForItem(at: IndexPath(item: $0, section: 0)) ?? .zero }
        return ElasticLayout.neighbor(of: index, direction: direction, in: frames) { isFocusable(visibleRows[$0]) }
    }

    private func showContextMenu(forRowAt index: Int) {
        let indexPath = IndexPath(item: index, section: 0)
        guard let frame = frameForItem(at: indexPath) else { return }
        if let node = visibleRows[index].node {
            isBulkContextMenu = selectedNodeIds.contains(node.id) && !selectedNodeIds.isEmpty
        }
        contextMenu(at: indexPath)?.popUp(positioning: nil, at: NSPoint(x: frame.minX + 40, y: frame.maxY), in: collectionView)
    }

    // MARK: - Drop Indicator

    private func showDropIndicator(at indexPath: IndexPath, operation: NSCollectionView.DropOperation) {
        switch operation {
        case .on:
            guard let frame = frameForItem(at: indexPath) else {
                hideDropIndicator()
                return
            }
            dropIndicator.showHighlight(in: frame.insetBy(dx: 2, dy: 2))
        case .before:
            guard let frame = insertionLineFrame(for: indexPath) else {
                hideDropIndicator()
                return
            }
            dropIndicator.showLine(in: frame)
        default:
            hideDropIndicator()
        }
    }

    private func hideDropIndicator() {
        dropIndicator.hide()
    }

    private func frameForItem(at indexPath: IndexPath) -> NSRect? {
        collectionView.layoutAttributesForItem(at: indexPath)?.frame
    }

    private func insertionLineFrame(for indexPath: IndexPath) -> NSRect? {
        let lineHeight: CGFloat = 2
        var depth = 0
        var y: CGFloat = listMetrics.verticalGap / 2

        if elasticMode == .mosaic, indexPath.item < visibleRows.count,
           let frame = frameForItem(at: indexPath), frame.width < collectionView.bounds.width * 0.9 {
            return NSRect(x: frame.minX - 5, y: frame.minY, width: lineHeight, height: frame.height)
        }
        if indexPath.item < visibleRows.count,
           let frame = frameForItem(at: indexPath) {
            depth = visibleRows[indexPath.item].depth
            y = frame.minY - listMetrics.verticalGap / 2
        } else if let lastIndex = visibleRows.indices.last,
                  let frame = frameForItem(at: IndexPath(item: lastIndex, section: 0)) {
            depth = 0
            y = frame.maxY + listMetrics.verticalGap / 2
        }

        let x = listMetrics.leftPadding + CGFloat(depth) * listMetrics.indentWidth
        let width = max(8, collectionView.bounds.width - x - listMetrics.leftPadding)
        return NSRect(x: x, y: y - lineHeight / 2, width: width, height: lineHeight)
    }

    private func shouldDropOnItem(at indexPath: IndexPath, draggingInfo: NSDraggingInfo) -> Bool {
        let location = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
            return true
        }
        let upper = frame.minY + frame.height * 0.25
        let lower = frame.maxY - frame.height * 0.25
        return location.y >= upper && location.y <= lower
    }
}

// MARK: - NSCollectionViewDataSource

extension NodeListViewController: NSCollectionViewDataSource {
    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleRows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let row = row(at: indexPath) else {
            return collectionView.makeItem(withIdentifier: NodeCollectionViewItem.identifier, for: indexPath)
        }
        let item = collectionView.makeItem(withIdentifier: itemIdentifier(for: row), for: indexPath)
        return configure(item, at: indexPath)
    }
}

extension NodeListViewController {
    /// Re-applies row content to on-screen cells whose identity didn't change but whose
    /// node did (folder expanded, task completed, title edited).
    func reconfigureVisibleItems() {
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item),
                  let row = row(at: indexPath) else { continue }
            let expected = itemIdentifier(for: row)
            let matches: Bool
            switch expected {
            case ArchiveHeaderItem.identifier: matches = item is ArchiveHeaderItem
            case SectionHeaderItem.identifier: matches = item is SectionHeaderItem
            case NodeTileItem.identifier: matches = item is NodeTileItem
            default: matches = item is NodeCollectionViewItem
            }
            guard matches else {
                // The row changed shape (e.g. a width change); redraw it with the right cell.
                collectionView.reloadItems(at: [indexPath])
                continue
            }
            _ = configure(item, at: indexPath)
        }
    }

    @discardableResult
    fileprivate func configure(_ item: NSCollectionViewItem, at indexPath: IndexPath) -> NSCollectionViewItem {
        guard let row = row(at: indexPath) else { return item }

        // Handle archive header row
        if case .archiveHeader(let count, let isExpanded) = row.kind {
            if let headerItem = item as? ArchiveHeaderItem {
                headerItem.configure(count: count, isExpanded: isExpanded, metrics: listMetrics) { [weak self] in
                    self?.onArchiveToggled?(!isExpanded)
                }
            }
            return item
        }

        if case .sectionHeader(let section, let meta, let isExpanded) = row.kind {
            if let header = item as? SectionHeaderItem {
                let title: String
                let symbol: String
                switch section {
                case .links: title = "Links"; symbol = "link"
                case .tasks: title = "Tasks"; symbol = "checkmark.square"
                case .snippets: title = "Snippets"; symbol = "chevron.left.forwardslash.chevron.right"
                }
                let style: SectionHeaderItem.Style = elasticMode == .list ? .countedRow : .label
                header.configure(style: style, title: title, meta: meta, symbol: style == .countedRow ? symbol : nil,
                                 isExpanded: isExpanded, metrics: listMetrics,
                                 horizontalInset: elasticMode == .mosaic ? 0 : 8)
                header.setKeyboardFocused(listHasFocus && row.id == keyboardCursorId)
            }
            return item
        }

        if let header = item as? SectionHeaderItem, case .folder(let folder)? = row.node {
            header.configure(style: .folderGroup, title: row.groupTitle ?? folder.name, meta: "\(folder.children.count)",
                             symbol: "folder", isExpanded: true, metrics: listMetrics, horizontalInset: 0)
            return item
        }

        guard item is NodeCollectionViewItem || item is NodeTileItem else { return item }
        guard let node = row.node else { return item }

        let isSelected = selectedNodeIds.contains(node.id)
        let isArchived: Bool
        if case .archived = row.kind { isArchived = true } else { isArchived = false }

        let kind: NodeRowContent.Kind
        let title: String
        var isOpen = false
        var codePreview: String?
        switch node {
        case .folder(let folder):
            title = folder.name
            kind = .folder(isExpanded: folder.isExpanded || isSearchActive, childCount: folder.children.count)
        case .link(let link):
            var favicon: NSImage?
            if let path = link.faviconPath,
               FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                favicon = image
            } else {
                FaviconPrefetcher.shared.request(links: [link], in: currentWorkspaceIdProvider?())
            }
            title = link.title
            kind = .link(favicon: favicon, domain: link.displayDomain)
            if !openKeys.isEmpty, let url = URL(string: link.url) {
                isOpen = openKeys.contains(BrowserTabService.canonicalize(url))
            }
        case .task(let task):
            title = task.title
            kind = .task(isCompleted: task.isCompleted, dueDate: task.dueDate)
        case .snippet(let snippet):
            title = snippet.title
            kind = .snippet(language: snippet.language)
            codePreview = snippet.content
        }
        let content = NodeRowContent(kind: kind, title: title, depth: row.depth, isArchived: isArchived,
                                     isOpen: isOpen, codePreview: codePreview)

        // After the content: the cursor ring, and jump letters (a–z for the first 26
        // items), which appear only in jump mode.
        func applyFocusAndHint(_ configurable: NodeItemConfigurable) {
            configurable.setKeyboardFocused(listHasFocus && row.id == keyboardCursorId)
            configurable.setHintCharacter(isJumpModeActive && !isArchived ? jumpLetter(at: indexPath.item) : nil)
        }
        if let tileItem = item as? NodeTileItem {
            tileItem.configure(content: content, metrics: listMetrics, isSelected: isSelected)
            applyFocusAndHint(tileItem)
            return tileItem
        }
        guard let nodeItem = item as? NodeCollectionViewItem else { return item }

        let isFolder: Bool
        if case .folder = node { isFolder = true } else { isFolder = false }
        let slotAction: (() -> Void)?
        if isArchived {
            slotAction = { [weak self] in self?.onNodeUnarchived?(node.id) }
        } else if isFolder {
            slotAction = nil
        } else {
            slotAction = { [weak self] in
                self?.onNodeDeleted?(node.id)
                self?.clearSelections()
            }
        }

        nodeItem.configure(
            content: content,
            metrics: listMetrics,
            isSelected: isSelected,
            showSlotAction: slotAction != nil,
            onSlotAction: slotAction
        )
        if case .folder(let folder) = node, !isSearchActive {
            nodeItem.onDisclosure = { [weak self] in
                self?.onFolderToggled?(folder.id, !folder.isExpanded)
            }
        } else {
            nodeItem.onDisclosure = nil
        }
        applyFocusAndHint(nodeItem)

        // Configure swipe actions per node type and archive state
        nodeItem.swipeEnabled = !isSearchActive

        if isArchived {
            nodeItem.setSwipeLeftIcon("trash", tintColor: .systemRed)
            nodeItem.onSwipeLeft = { [weak self] in
                self?.onNodePermanentlyDeleted?(node.id)
            }
            nodeItem.setSwipeRightIcon("arrow.uturn.backward", tintColor: .systemBlue)
            nodeItem.onSwipeRight = { [weak self] in
                self?.onNodeUnarchived?(node.id)
            }
        } else {
            nodeItem.setSwipeLeftIcon("archivebox", tintColor: .systemOrange)
            nodeItem.onSwipeLeft = { [weak self] in
                self?.onNodeDeleted?(node.id)
                self?.clearSelections()
            }

            switch node {
            case .link(let link):
                nodeItem.setSwipeRightIcon("arrow.up.right", tintColor: .systemBlue)
                nodeItem.onSwipeRight = { [weak self] in
                    self?.onNodeSelected?(link.id)
                }
            case .task(let task):
                nodeItem.setSwipeRightIcon(
                    task.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle",
                    tintColor: .systemGreen
                )
                nodeItem.onSwipeRight = { [weak self] in
                    self?.onTaskToggled?(task.id)
                }
            case .snippet(let snippet):
                nodeItem.setSwipeRightIcon("doc.on.doc", tintColor: .systemOrange)
                nodeItem.onSwipeRight = { [weak self] in
                    self?.onSnippetClicked?(snippet.id)
                }
            case .folder:
                nodeItem.setSwipeRightIcon("folder", tintColor: .systemGray)
                nodeItem.onSwipeRight = nil
            }
        }

        return nodeItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let row = row(at: indexPath) else { return }
        if pendingInsertedIds.remove(row.id) != nil {
            animateInsert(item: item)
        } else {
            item.view.alphaValue = 1
        }
    }
}

// MARK: - NSCollectionViewDelegate

extension NodeListViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        guard !isSearchActive else {
            return false
        }

        guard selectedNodeIds.isEmpty else {
            return false
        }

        // Don't allow dragging archive header or archived items
        for indexPath in indexPaths {
            if let row = row(at: indexPath) {
                switch row.kind {
                case .archiveHeader, .archived, .sectionHeader:
                    return false
                case .regular:
                    if shape(for: row) == .groupHeader { return false }
                }
            }
        }

        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, let row = row(at: indexPath) else { return }

        // Handle archive header click
        if case .archiveHeader(_, let isExpanded) = row.kind {
            collectionView.deselectItems(at: indexPaths)
            onArchiveToggled?(!isExpanded)
            return
        }
        if case .sectionHeader(let section, _, _) = row.kind {
            collectionView.deselectItems(at: indexPaths)
            if elasticMode == .list {
                keyboardCursorId = row.id
                toggleListSection(section)
            }
            return
        }
        if shape(for: row) == .groupHeader {
            collectionView.deselectItems(at: indexPaths)
            return
        }

        guard let node = row.node else {
            collectionView.deselectItems(at: indexPaths)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDraggingItems { return }
            if self.suppressNextSelection {
                self.suppressNextSelection = false
                self.collectionView.deselectItems(at: indexPaths)
                return
            }
            if self.inlineRenameNodeId != nil {
                self.collectionView.deselectItems(at: indexPaths)
                return
            }
            if !self.collectionView.selectionIndexPaths.contains(indexPath) { return }

            // Check for Cmd key modifier for multi-selection
            if NSEvent.modifierFlags.contains(.command) {
                self.toggleSelection(for: node.id)
                self.collectionView.deselectItems(at: indexPaths)
                return
            }

            // Clear selections on regular click
            if !self.selectedNodeIds.isEmpty {
                self.clearSelections()
            }

            self.keyboardCursorId = row.id
            self.activate(node)

            self.collectionView.deselectItems(at: indexPaths)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let row = row(at: indexPath), let node = row.node else { return nil }
        // Don't allow dragging archive header or archived items
        if case .archived = row.kind { return nil }
        if case .archiveHeader = row.kind { return nil }
        if shape(for: row) == .groupHeader { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.id.uuidString, forType: nodePasteboardType)
        return pasteboardItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        isDraggingItems = true
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        isDraggingItems = false
        hideDropIndicator()
        restoreDraggedItems()
    }

    /// Shows every on-screen item again. The collection view hides the dragged one, and
    /// after a drop elsewhere (a workspace tab) or a missed one it could stay blank.
    func restoreDraggedItems() {
        for item in collectionView.visibleItems() {
            item.view.isHidden = false
            item.view.alphaValue = 1
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        if isSearchActive {
            hideDropIndicator()
            return []
        }

        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let isItemDrag = draggingInfo.draggingPasteboard.availableType(from: [nodePasteboardType]) != nil
        if !isItemDrag, onDropText == nil || EmptyStateView.droppedText(from: draggingInfo)?.isEmpty != false {
            hideDropIndicator()
            return []
        }
        guard dropStaysInSection(indexPath, draggingInfo: draggingInfo) else {
            hideDropIndicator()
            return []
        }
        let draggedSection = draggedRow(draggingInfo)?.section ?? .links
        if draggedSection == .links,
           indexPath.item < visibleRows.count,
           let row = row(at: indexPath),
           let node = row.node,
           case .folder = node,
           shouldDropOnItem(at: indexPath, draggingInfo: draggingInfo) {
            proposedDropOperation.pointee = .on
        } else {
            proposedDropOperation.pointee = .before
        }

        showDropIndicator(at: indexPath, operation: proposedDropOperation.pointee)

        return isItemDrag ? .move : .copy
    }

    private func draggedRow(_ draggingInfo: NSDraggingInfo) -> NodeListRow? {
        guard let idString = draggingInfo.draggingPasteboard.string(forType: nodePasteboardType),
              let nodeId = UUID(uuidString: idString) else { return nil }
        return visibleRows.first { $0.id == nodeId }
    }

    /// Tasks and snippets reorder within their own section; links and folders stay above
    /// the sections. A drop at a section's end lands after its last item.
    private func dropStaysInSection(_ indexPath: IndexPath, draggingInfo: NSDraggingInfo) -> Bool {
        guard let dragged = draggedRow(draggingInfo) else { return true }
        let rows = visibleRows
        let item = indexPath.item
        let members = rows.indices.filter { rows[$0].section == dragged.section && rows[$0].node != nil }
        switch dragged.section {
        case .tasks, .snippets:
            guard let first = members.first, let last = members.last else { return false }
            return item >= first && item <= last + 1
        case .links:
            let boundary = rows.firstIndex { row in
                switch row.kind {
                case .sectionHeader(let section, _, _): return section != .links
                case .archiveHeader: return true
                default: return false
                }
            } ?? rows.count
            if item < rows.count, case .sectionHeader(.links, _, _) = rows[item].kind { return false }
            return item <= boundary
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        hideDropIndicator()
        guard let idString = draggingInfo.draggingPasteboard.string(forType: nodePasteboardType),
              let nodeId = UUID(uuidString: idString) else {
            guard let text = EmptyStateView.droppedText(from: draggingInfo), !text.isEmpty, let onDropText else { return false }
            let target = dropDestination(at: indexPath, operation: dropOperation)
            onDropText(text, target.parentId, target.index)
            return true
        }
        let intoFolder = draggedRow(draggingInfo)?.section ?? .links == .links
        let target = dropDestination(at: indexPath, operation: intoFolder ? dropOperation : .before)
        onNodeMoved?(nodeId, target.parentId, target.index)
        return true
    }

    /// Where a drop at `indexPath` lands: inside a folder dropped `.on`, else before the
    /// row's item in its parent, or at the end of the top level past the last row.
    func dropDestination(at indexPath: IndexPath, operation: NSCollectionView.DropOperation) -> (parentId: UUID?, index: Int) {
        let end = nodeProvider?().count ?? 0
        guard indexPath.item < visibleRows.count, let dropNode = row(at: indexPath)?.node else { return (nil, end) }
        if operation == .on, case .folder(let folder) = dropNode {
            return (folder.id, folder.children.count)
        }
        guard let location = findNodeLocation?(dropNode.id), location.index >= 0 else { return (nil, end) }
        return (location.parentId, location.index)
    }
}

// MARK: - Context menus

extension NodeListViewController: NewItemMenuTarget {
    /// The menu for a right-click (or ⌥↩) at `indexPath`: the selection's bulk menu, an
    /// archived item's menu, the item's NodeMenu, or the New… menu on the background.
    func contextMenu(at indexPath: IndexPath?) -> NSMenu? {
        if isBulkContextMenu && !selectedNodeIds.isEmpty {
            let menu = NSMenu()
            populateBulkContextMenu(menu)
            return menu
        }
        guard let indexPath, let row = row(at: indexPath) else {
            return NewItemMenu.make(includePaste: false, includeImport: false, target: self)
        }
        guard let node = row.node else {
            if case .archiveHeader = row.kind { return nil }
            return NewItemMenu.make(includePaste: false, includeImport: false, target: self)
        }
        if case .archived = row.kind {
            let menu = NSMenu()
            let unarchive = NSMenuItem(title: "Unarchive", action: #selector(contextUnarchive(_:)), keyEquivalent: "")
            unarchive.target = self
            unarchive.representedObject = node.id
            menu.addItem(unarchive)
            let permDelete = NSMenuItem(title: "Delete permanently", action: #selector(contextPermanentlyDelete(_:)), keyEquivalent: "")
            permDelete.target = self
            permDelete.representedObject = node.id
            menu.addItem(permDelete)
            return menu
        }
        return nodeMenuProvider?(node)
    }

    func newFolderFromMenu(_ sender: Any?) { onNewFolderRequested?(nil) }
    func newTaskFromMenu(_ sender: Any?) { onNewTaskRequested?(nil) }
    func newSnippetFromMenu(_ sender: Any?) { onNewSnippetRequested?(nil) }
    func newWorkspaceFromMenu(_ sender: Any?) { onNewWorkspaceRequested?() }

    @objc private func contextUnarchive(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodeUnarchived?(nodeId)
    }

    @objc private func contextPermanentlyDelete(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodePermanentlyDeleted?(nodeId)
    }

    // MARK: Rename and Edit URL

    /// Renames in place on a list row; anywhere a row can't edit its own title (a mosaic
    /// tile or group header), in the rename flyout beside it, which it returns.
    @discardableResult
    func beginRename(for nodeId: UUID) -> TextFieldFlyout? {
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }) else { return nil }
        return beginInlineRename(nodeId: nodeId, indexPath: IndexPath(item: index, section: 0))
    }

    /// The rename flyout beside the item's row or tile, or beside `anchor` (a rail cell).
    /// `onEnd` runs after it saves or cancels.
    @discardableResult
    func presentRenameFlyout(for nodeId: UUID, from anchor: NSView? = nil,
                             onEnd: (() -> Void)? = nil) -> TextFieldFlyout? {
        guard let node = findNodeById?(nodeId), let anchor = anchor ?? rowAnchorView(for: nodeId) else { return nil }
        return TextFieldFlyout.present(in: flyouts, title: "Rename", value: node.displayName, placeholder: "Name",
                                       from: anchor, onSave: { [weak self] name in
                                           onEnd?()
                                           guard name != node.displayName else { return }
                                           self?.onNodeRenamed?(nodeId, name)
                                       }, onCancel: onEnd)
    }

    /// Edit URL… in a flyout beside the link's row (or `anchor`), instead of an app-modal alert.
    @discardableResult
    func presentEditURLFlyout(for nodeId: UUID, from anchor: NSView? = nil) -> TextFieldFlyout? {
        guard case .link(let link)? = findNodeById?(nodeId), let anchor = anchor ?? rowAnchorView(for: nodeId) else { return nil }
        return TextFieldFlyout.present(in: flyouts, title: "Edit URL", detail: link.title, value: link.url,
                                       placeholder: "https://", monospaced: true, from: anchor,
                                       onSave: { [weak self] url in
                                           guard url != link.url else { return }
                                           self?.onLinkUrlEdited?(nodeId, url)
                                       })
    }
    private func populateBulkContextMenu(_ menu: NSMenu) {
        let count = selectedNodeIds.count

        // 1. Move to Workspace submenu
        let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let moveSubmenu = NSMenu()
        var hasBulkWorkspaceItems = false
        let bulkCurrentWsId = currentWorkspaceIdProvider?()
        if let workspaces = workspacesProvider?() {
            for workspace in workspaces where workspace.id != bulkCurrentWsId {
                let item = NSMenuItem(title: workspace.name, action: #selector(bulkMoveToWorkspace), keyEquivalent: "")
                item.target = self
                item.representedObject = workspace.id
                moveSubmenu.addItem(item)
                hasBulkWorkspaceItems = true
            }
        }
        if hasBulkWorkspaceItems {
            moveSubmenu.addItem(NSMenuItem.separator())
        }
        let bulkNewWorkspaceItem = NSMenuItem(title: "New workspace…", action: #selector(bulkMoveToNewWorkspace), keyEquivalent: "")
        bulkNewWorkspaceItem.target = self
        moveSubmenu.addItem(bulkNewWorkspaceItem)

        let bulkNewFolderItem = NSMenuItem(title: "New folder", action: #selector(bulkMoveToNewFolder), keyEquivalent: "")
        bulkNewFolderItem.target = self
        moveSubmenu.addItem(bulkNewFolderItem)

        moveItem.submenu = moveSubmenu
        menu.addItem(moveItem)

        // 2. Group in New Folder
        let groupItem = NSMenuItem(title: "Group in new folder", action: #selector(bulkGroupInFolder), keyEquivalent: "")
        groupItem.target = self
        menu.addItem(groupItem)

        // 3. Copy Links (only if there are links)
        let nodes = selectedNodeIds.compactMap { id in
            findNodeInNodes?(id, nodeProvider?() ?? [])
        }
        let linkCount = nodes.filter { node in
            if case .link = node { return true }
            return false
        }.count

        if linkCount > 0 {
            let openItem = NSMenuItem(title: "Open \(linkCount) link\(linkCount > 1 ? "s" : "")", action: #selector(bulkOpenLinks), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)

            let copyItem = NSMenuItem(title: "Copy \(linkCount) link\(linkCount > 1 ? "s" : "")", action: #selector(bulkCopyLinks), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 4. Archive All
        let deleteItem = NSMenuItem(title: "Archive \(count) item\(count > 1 ? "s" : "")", action: #selector(bulkDelete), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
    }

    @objc private func bulkMoveToWorkspace(_ sender: NSMenuItem) {
        guard let workspaceId = sender.representedObject as? UUID else { return }
        let nodeIds = Array(selectedNodeIds)
        onBulkNodesMovedToWorkspace?(nodeIds, workspaceId)
        clearSelections()
    }

    @objc private func bulkMoveToNewWorkspace() {
        let nodeIds = Array(selectedNodeIds)
        guard !nodeIds.isEmpty else { return }
        onMoveToNewWorkspace?(nodeIds)
        clearSelections()
    }

    @objc private func bulkMoveToNewFolder() {
        let nodeIds = Array(selectedNodeIds)
        guard !nodeIds.isEmpty else { return }
        onMoveToNewFolder?(nodeIds)
        clearSelections()
    }

    @objc private func bulkGroupInFolder() {
        let nodeIds = Array(selectedNodeIds)
        guard !nodeIds.isEmpty else { return }

        if let folderId = onBulkNodesGrouped?(nodeIds, "Untitled") {
            DispatchQueue.main.async { [weak self] in
                self?.clearSelections()
            }
            scheduleInlineRename(for: folderId)
        }
    }

    @objc private func bulkCopyLinks() {
        onBulkNodesCopied?(Array(selectedNodeIds))
        clearSelections()
    }

    @objc private func bulkOpenLinks() {
        let nodeIds = Array(selectedNodeIds)
        guard !nodeIds.isEmpty else { return }
        onBulkOpenLinks?(nodeIds)
        clearSelections()
    }

    @objc private func bulkDelete() {
        guard selectedNodeIds.count > 0 else { return }
        onBulkNodesDeleted?(Array(selectedNodeIds))
        clearSelections()
    }
}

// MARK: - Supporting Types

/// Where a row lives: the link-and-folder tree, or one of the sections below it.
enum NodeSection: Hashable {
    case links, tasks, snippets
}

private struct ReloadInput {
    let nodes: [Node]
    let forceExpand: Bool
    let archivedNodes: [Node]
    let isArchiveExpanded: Bool
    let showArchiveDuringSearch: Bool
}

private enum NodeListRowKind {
    case regular
    case archiveHeader(count: Int, isExpanded: Bool)
    case archived
    /// "TASKS · 2 open". At list width it's the counted row that expands in place.
    case sectionHeader(section: NodeSection, meta: String, isExpanded: Bool)
}

private struct NodeListRow {
    let node: Node?
    let depth: Int
    let kind: NodeListRowKind
    let rowId: UUID
    let section: NodeSection
    /// A mosaic folder group's label, with its parents ("Design refs › Type").
    var groupTitle: String?

    init(node: Node, depth: Int, kind: NodeListRowKind = .regular, section: NodeSection = .links, groupTitle: String? = nil) {
        self.node = node
        self.depth = depth
        self.kind = kind
        self.section = section
        self.groupTitle = groupTitle
        if case .archived = kind {
            self.rowId = archivedRowId(for: node.id)
        } else {
            self.rowId = node.id
        }
    }

    init(archiveHeaderCount: Int, isExpanded: Bool) {
        self.node = nil
        self.depth = 0
        self.kind = .archiveHeader(count: archiveHeaderCount, isExpanded: isExpanded)
        self.rowId = archiveHeaderUUID
        self.section = .links
    }

    init(section: NodeSection, meta: String, isExpanded: Bool) {
        self.node = nil
        self.depth = 0
        self.kind = .sectionHeader(section: section, meta: meta, isExpanded: isExpanded)
        self.section = section
        switch section {
        case .links: self.rowId = linksHeaderUUID
        case .tasks: self.rowId = tasksHeaderUUID
        case .snippets: self.rowId = snippetsHeaderUUID
        }
    }

    var id: UUID {
        rowId
    }
}

private final class DropIndicatorView: NSView {
    private let lineThickness: CGFloat = 2
    private let highlightCornerRadius: CGFloat = 8
    var accentColor: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    func showLine(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = lineThickness / 2
        layer?.backgroundColor = resolvedCGColor(accentColor)
        layer?.borderWidth = 0
    }

    func showHighlight(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = highlightCornerRadius
        layer?.backgroundColor = resolvedCGColor(accentColor.withAlphaComponent(0.12))
        layer?.borderColor = resolvedCGColor(accentColor)
        layer?.borderWidth = 2
    }

    func hide() {
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class ContextMenuCollectionView: NSCollectionView {
    var onDragExit: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    weak var parentViewController: NodeListViewController?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: location)
        parentViewController?.mouseInteractionOccurred()

        // If clicking on empty space, notify the callback
        if indexPath == nil {
            onBackgroundClick?()
        }

        // Always call super to allow normal click handling
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: location)

        // Check if clicked item is in selection for bulk context menu
        if let parentVC = parentViewController {
            if let indexPath = indexPath,
               let row = parentVC.row(at: indexPath),
               let node = row.node,
               parentVC.selectedNodeIds.contains(node.id),
               parentVC.selectedNodeIds.count > 0 {
                parentVC.isBulkContextMenu = true
            } else {
                parentVC.isBulkContextMenu = false
            }
        }

        return parentViewController?.contextMenu(at: indexPath)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    // NSCollectionView's own arrow-key handling selects items, and selecting an item
    // activates it here, so all list keys go through the controller instead.
    override func keyDown(with event: NSEvent) {
        if parentViewController?.handleListKey(event) == true { return }
        let arrowKeys: Set<UInt16> = [123, 124, 125, 126]
        if arrowKeys.contains(event.keyCode) { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        parentViewController?.listFocusChanged()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        parentViewController?.listFocusChanged()
        return ok
    }
}

// MARK: - Archive Header Item

private final class ArchiveHeaderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ArchiveHeaderItem")

    private let disclosureIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var onClick: (() -> Void)?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        disclosureIcon.translatesAutoresizingMaskIntoConstraints = false
        disclosureIcon.imageScaling = .scaleProportionallyDown
        disclosureIcon.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = StowTheme.Font.section
        titleLabel.lineBreakMode = .byTruncatingTail

        container.addSubview(disclosureIcon)
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            disclosureIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: StowTheme.List.horizontalInset),
            disclosureIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            disclosureIcon.widthAnchor.constraint(equalToConstant: StowTheme.List.disclosureWidth),
            disclosureIcon.heightAnchor.constraint(equalToConstant: StowTheme.List.disclosureWidth),

            titleLabel.leadingAnchor.constraint(equalTo: disclosureIcon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])
    }

    func configure(count: Int, isExpanded: Bool, metrics: ListMetrics, onClick: @escaping () -> Void) {
        self.onClick = onClick
        titleLabel.stringValue = "Archive · \(count)"
        titleLabel.textColor = metrics.secondaryColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Archive, \(count) items, \(isExpanded ? "expanded" : "collapsed")")

        let chevronName = isExpanded ? "chevron.down" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        let icon = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        icon?.isTemplate = true
        disclosureIcon.image = icon
        disclosureIcon.contentTintColor = metrics.secondaryColor
    }
}
