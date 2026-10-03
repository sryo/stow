//
//  NodeListViewController.swift
//  Stow
//

import AppKit

private let archiveHeaderUUID = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFFF")!
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
    private let contextMenu = NSMenu()

    // Overscroll shadow views
    private let topShadowView = NSView()
    private let bottomShadowView = NSView()

    private var visibleRows: [NodeListRow] = []
    private var contextIndexPath: IndexPath?
    private var isDraggingItems = false
    private var pendingInsertedIds: Set<UUID> = []
    private let rowAnimationDuration: TimeInterval = 0.16
    private let rowAnimationOffset: CGFloat = 10

    // Multi-selection support
    fileprivate var selectedNodeIds: Set<UUID> = []
    fileprivate var isBulkContextMenu = false

    // Inline rename support
    private weak var inlineRenameItem: NodeCollectionViewItem?
    var inlineRenameNodeId: UUID?
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
    var onBulkOpenLinks: (([UUID]) -> Void)?
    var onMoveToNewWorkspace: (([UUID]) -> Void)?
    var onMoveToNewFolder: (([UUID]) -> Void)?
    var onNodeUnarchived: ((UUID) -> Void)?
    var onNodePermanentlyDeleted: ((UUID) -> Void)?
    var onArchiveToggled: ((Bool) -> Void)?

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
            (collectionView.collectionViewLayout as? ListFlowLayout)?.update(metrics: listMetrics)
            collectionView.reloadData()
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

    private func jumpLetter(at item: Int) -> String? {
        item < jumpLetters.count ? String(jumpLetters[item]) : nil
    }

    /// The row index a jump letter points at, if any.
    func rowIndex(forJumpLetter letter: Character) -> Int? {
        jumpLetters.firstIndex(of: letter)
    }

    /// While true, rows show a–z jump letters and plain letter keys activate rows.
    var isJumpModeActive = false {
        didSet {
            guard isJumpModeActive != oldValue else { return }
            for item in collectionView.visibleItems() {
                guard let nodeItem = item as? NodeCollectionViewItem,
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
        collectionView.collectionViewLayout = ListFlowLayout(metrics: listMetrics)
        collectionView.register(NodeCollectionViewItem.self, forItemWithIdentifier: NodeCollectionViewItem.identifier)
        collectionView.register(NodeTileItem.self, forItemWithIdentifier: NodeTileItem.identifier)
        collectionView.register(ArchiveHeaderItem.self, forItemWithIdentifier: ArchiveHeaderItem.identifier)
        collectionView.registerForDraggedTypes([nodePasteboardType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        collectionView.onContextRequest = { [weak self] indexPath in
            self?.contextIndexPath = indexPath
        }
        collectionView.onDragExit = { [weak self] in
            self?.hideDropIndicator()
        }
        collectionView.onBackgroundClick = { [weak self] in
            self?.clearSelections()
        }
        collectionView.parentViewController = self

        dropIndicator.isHidden = true
        collectionView.addSubview(dropIndicator)

        contextMenu.delegate = self
        collectionView.menu = contextMenu
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
        var newRows = buildVisibleRows(nodes: nodes, depth: 0, forceExpand: forceExpand)

        // Append archive section if there are archived items and not searching
        if !archivedNodes.isEmpty && (!isSearchActive || showArchiveDuringSearch) {
            newRows.append(NodeListRow(archiveHeaderCount: archivedNodes.count, isExpanded: isArchiveExpanded))
            if isArchiveExpanded {
                newRows.append(contentsOf: buildArchivedRows(nodes: archivedNodes, depth: 0))
            }
        }

        if !animated {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        applyVisibleRows(newRows)
        handlePendingInlineRename()
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
            clearInlineRenameState()
        }
    }

    /// Returns the node at the given visible index, or nil if out of range
    func visibleNode(at index: Int) -> Node? {
        guard index >= 0, index < visibleRows.count else { return nil }
        return visibleRows[index].node
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
        if isSearchActive || collectionView.window == nil {
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

    private func handlePendingInlineRename() {
        guard let nodeId = pendingInlineRenameId else { return }
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }) else { return }
        let indexPath = IndexPath(item: index, section: 0)
        pendingInlineRenameId = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
            if self.collectionView.item(at: indexPath) is NodeCollectionViewItem {
                self.beginInlineRename(nodeId: nodeId, indexPath: indexPath)
            } else {
                self.pendingInlineRenameId = nodeId
            }
        }
    }

    private func beginInlineRename(nodeId: UUID, indexPath: IndexPath) {
        cancelInlineRename()
        guard findNodeById?(nodeId) != nil,
              let item = collectionView.item(at: indexPath) as? NodeCollectionViewItem else {
            clearInlineRenameState()
            return
        }

        inlineRenameNodeId = nodeId
        inlineRenameItem = item
        item.beginInlineRename(onCommit: { [weak self] newName in
            self?.commitInlineRename(newName)
        }, onCancel: { [weak self] in
            self?.handleInlineRenameCancelled()
        })
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
    }

    private func handleInlineRenameCancelled() {
        suppressNextSelection = true
        clearInlineRenameState()
    }

    private func clearInlineRenameState() {
        inlineRenameItem = nil
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
            keyboardCursorId = visibleRows.first(where: { $0.node != nil })?.id
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
            keyboardCursorId = visibleRows.first(where: { $0.node != nil })?.id
        }
        updateKeyboardCursorVisuals()
    }

    private func updateKeyboardCursorVisuals() {
        let showRing = listHasFocus
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item), let row = row(at: indexPath) else { continue }
            let focused = showRing && row.id == keyboardCursorId
            (item as? NodeCollectionViewItem)?.setKeyboardFocused(focused)
            (item as? NodeTileItem)?.setKeyboardFocused(focused)
        }
    }

    private var cursorIndex: Int? {
        guard let id = keyboardCursorId else { return nil }
        return visibleRows.firstIndex(where: { $0.id == id })
    }

    private func moveCursor(to index: Int) {
        guard !visibleRows.isEmpty else { return }
        let clamped = min(max(index, 0), visibleRows.count - 1)
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
                keyboardCursorId = visibleRows.first(where: { $0.node != nil })?.id
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
            }

        case (36, []), (76, []): // return, enter
            guard let row else { return true }
            if case .archiveHeader(_, let isExpanded) = row.kind {
                onArchiveToggled?(!isExpanded)
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

    private func showContextMenu(forRowAt index: Int) {
        let indexPath = IndexPath(item: index, section: 0)
        guard let frame = frameForItem(at: indexPath) else { return }
        contextIndexPath = indexPath
        if let node = visibleRows[index].node {
            isBulkContextMenu = selectedNodeIds.contains(node.id) && !selectedNodeIds.isEmpty
        }
        contextMenu.popUp(positioning: nil, at: NSPoint(x: frame.minX + 40, y: frame.maxY), in: collectionView)
    }

    /// Shown in context menus as hints for the list's keyboard shortcuts (F2, ⌘⌫).
    fileprivate static let renameKey = String(Character(UnicodeScalar(NSF2FunctionKey)!))
    fileprivate static let archiveKey = String(Character(UnicodeScalar(NSBackspaceCharacter)!))

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
        let identifier: NSUserInterfaceItemIdentifier
        if case .archiveHeader = row.kind {
            identifier = ArchiveHeaderItem.identifier
        } else {
            identifier = listMetrics.mode == .mosaic ? NodeTileItem.identifier : NodeCollectionViewItem.identifier
        }
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
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
            let isHeader: Bool
            if case .archiveHeader = row.kind { isHeader = true } else { isHeader = false }
            guard isHeader == (item is ArchiveHeaderItem) else { continue }
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

        guard item is NodeCollectionViewItem || item is NodeTileItem else { return item }
        guard let node = row.node else { return item }

        let isSelected = selectedNodeIds.contains(node.id)
        let isArchived: Bool
        if case .archived = row.kind { isArchived = true } else { isArchived = false }

        let kind: NodeRowContent.Kind
        let title: String
        var shouldFetchFavicon: URL?
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
                shouldFetchFavicon = URL(string: link.url)
            }
            title = link.title
            kind = .link(favicon: favicon, domain: link.displayDomain)
        case .task(let task):
            title = task.title
            kind = .task(isCompleted: task.isCompleted, dueDate: task.dueDate)
        case .snippet(let snippet):
            title = snippet.title
            kind = .snippet(language: snippet.language)
        }

        if let tileItem = item as? NodeTileItem {
            tileItem.configure(content: NodeRowContent(kind: kind, title: title, depth: row.depth, isArchived: isArchived),
                               metrics: listMetrics, isSelected: isSelected)
            tileItem.setKeyboardFocused(listHasFocus && row.id == keyboardCursorId)
            if let url = shouldFetchFavicon, case .link(let link) = node {
                FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { _, path in
                    guard let path else { return }
                    NotificationCenter.default.post(name: .init("UpdateLinkFavicon"), object: nil, userInfo: ["linkId": link.id, "path": path])
                }
            }
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
            content: NodeRowContent(kind: kind, title: title, depth: row.depth, isArchived: isArchived),
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

        if let url = shouldFetchFavicon, case .link(let link) = node {
            FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { _, path in
                guard let path else { return }
                NotificationCenter.default.post(
                    name: .init("UpdateLinkFavicon"),
                    object: nil,
                    userInfo: ["linkId": link.id, "path": path]
                )
            }
        }

        nodeItem.setKeyboardFocused(listHasFocus && row.id == keyboardCursorId)

        // Jump letters (a–z for the first 26 rows) appear only in jump mode.
        if isJumpModeActive && !isArchived, let letter = jumpLetter(at: indexPath.item) {
            nodeItem.setHintCharacter(letter)
        } else {
            nodeItem.setHintCharacter(nil)
        }

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
                case .archiveHeader, .archived:
                    return false
                case .regular:
                    break
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
        if indexPath.item < visibleRows.count,
           let row = row(at: indexPath),
           let node = row.node,
           case .folder = node,
           shouldDropOnItem(at: indexPath, draggingInfo: draggingInfo) {
            proposedDropOperation.pointee = .on
        } else {
            proposedDropOperation.pointee = .before
        }

        showDropIndicator(at: indexPath, operation: proposedDropOperation.pointee)

        return .move
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        hideDropIndicator()
        guard let idString = draggingInfo.draggingPasteboard.string(forType: nodePasteboardType),
              let nodeId = UUID(uuidString: idString),
              let nodes = nodeProvider?() else { return false }

        var targetParentId: UUID?
        var targetIndex: Int

        if indexPath.item < visibleRows.count, let row = row(at: indexPath), let dropNode = row.node {
            switch dropNode {
            case .folder(let folder):
                if dropOperation == .on {
                    targetParentId = folder.id
                    targetIndex = folder.children.count
                } else if let location = findNodeLocation?(folder.id) {
                    targetParentId = location.parentId
                    targetIndex = location.index
                } else {
                    targetParentId = nil
                    targetIndex = nodes.count
                }
            case .link, .task, .snippet:
                if let location = findNodeLocation?(dropNode.id) {
                    targetParentId = location.parentId
                    targetIndex = location.index
                } else {
                    targetParentId = nil
                    targetIndex = nodes.count
                }
            }
        } else {
            targetParentId = nil
            targetIndex = nodes.count
        }

        if targetIndex < 0 { targetIndex = nodes.count }
        onNodeMoved?(nodeId, targetParentId, targetIndex)
        return true
    }
}

// MARK: - NSMenuDelegate

extension NodeListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Check for bulk selection context menu
        if isBulkContextMenu && selectedNodeIds.count > 0 {
            populateBulkContextMenu(menu)
            return
        }

        guard let indexPath = contextIndexPath,
              let row = row(at: indexPath),
              let node = row.node else {
            // No archive header context menu either
            if let indexPath = contextIndexPath, let row = row(at: indexPath),
               case .archiveHeader = row.kind {
                return
            }
            let newFolder = NSMenuItem(title: "New folder…", action: #selector(contextNewFolder), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)

            let newTask = NSMenuItem(title: "New task…", action: #selector(contextNewTask), keyEquivalent: "")
            newTask.target = self
            menu.addItem(newTask)

            let newSnippet = NSMenuItem(title: "New snippet…", action: #selector(contextNewSnippet), keyEquivalent: "")
            newSnippet.target = self
            menu.addItem(newSnippet)
            return
        }

        // Archived items get a different context menu
        if case .archived = row.kind {
            let unarchive = NSMenuItem(title: "Unarchive", action: #selector(contextUnarchive(_:)), keyEquivalent: "")
            unarchive.target = self
            unarchive.representedObject = node.id
            menu.addItem(unarchive)

            let permDelete = NSMenuItem(title: "Delete Permanently", action: #selector(contextPermanentlyDelete(_:)), keyEquivalent: "")
            permDelete.target = self
            permDelete.representedObject = node.id
            menu.addItem(permDelete)
            return
        }

        // Common items helper
        func addMoveToSubmenu() {
            let moveMenu = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            var hasWorkspaceItems = false
            let currentWsId = currentWorkspaceIdProvider?()
            if let workspaces = workspacesProvider?() {
                for workspace in workspaces where workspace.id != currentWsId {
                    let item = NSMenuItem(title: workspace.name, action: #selector(contextMoveToWorkspace), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["nodeId": node.id, "workspaceId": workspace.id]
                    submenu.addItem(item)
                    hasWorkspaceItems = true
                }
            }
            if hasWorkspaceItems {
                submenu.addItem(NSMenuItem.separator())
            }
            let newWorkspaceItem = NSMenuItem(title: "New workspace…", action: #selector(contextMoveToNewWorkspace(_:)), keyEquivalent: "")
            newWorkspaceItem.target = self
            newWorkspaceItem.representedObject = [node.id]
            submenu.addItem(newWorkspaceItem)

            let newFolderItem = NSMenuItem(title: "New folder", action: #selector(contextMoveToNewFolder(_:)), keyEquivalent: "")
            newFolderItem.target = self
            newFolderItem.representedObject = [node.id]
            submenu.addItem(newFolderItem)

            moveMenu.submenu = submenu
            menu.addItem(moveMenu)
        }

        switch node {
        case .folder(let folder):
            let newNested = NSMenuItem(title: "New folder inside…", action: #selector(contextNewNestedFolder(_:)), keyEquivalent: "")
            newNested.target = self
            newNested.representedObject = node.id
            menu.addItem(newNested)

            // Count links in folder
            let folderLinkCount = countLinksInFolder(folder)
            if folderLinkCount > 0 {
                let openAll = NSMenuItem(title: "Open All Links", action: #selector(contextOpenFolderLinks(_:)), keyEquivalent: "")
                openAll.target = self
                openAll.representedObject = folder.id
                menu.addItem(openAll)
            }

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: Self.renameKey)
            rename.keyEquivalentModifierMask = []
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let archive = NSMenuItem(title: "Archive", action: #selector(contextDelete), keyEquivalent: Self.archiveKey)
            archive.target = self
            archive.representedObject = node.id
            menu.addItem(archive)
        case .link(let link):
            let editUrl = NSMenuItem(title: "Edit URL…", action: #selector(contextEditUrl(_:)), keyEquivalent: "")
            editUrl.target = self
            editUrl.representedObject = ["nodeId": link.id, "currentUrl": link.url]
            menu.addItem(editUrl)

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: Self.renameKey)
            rename.keyEquivalentModifierMask = []
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let archive = NSMenuItem(title: "Archive", action: #selector(contextDelete), keyEquivalent: Self.archiveKey)
            archive.target = self
            archive.representedObject = node.id
            menu.addItem(archive)
        case .task(let task):
            let toggleTitle = task.isCompleted ? "Mark incomplete" : "Mark complete"
            let toggle = NSMenuItem(title: toggleTitle, action: #selector(contextToggleTask), keyEquivalent: "")
            toggle.target = self
            toggle.representedObject = node.id
            menu.addItem(toggle)

            let dueDate = NSMenuItem(title: "Set due date…", action: #selector(contextSetDueDate), keyEquivalent: "")
            dueDate.target = self
            dueDate.representedObject = node.id
            menu.addItem(dueDate)

            if task.dueDate != nil {
                let clearDueDate = NSMenuItem(title: "Clear due date", action: #selector(contextClearDueDate), keyEquivalent: "")
                clearDueDate.target = self
                clearDueDate.representedObject = node.id
                menu.addItem(clearDueDate)
            }

            menu.addItem(NSMenuItem.separator())

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: Self.renameKey)
            rename.keyEquivalentModifierMask = []
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let archive = NSMenuItem(title: "Archive", action: #selector(contextDelete), keyEquivalent: Self.archiveKey)
            archive.target = self
            archive.representedObject = node.id
            menu.addItem(archive)
        case .snippet:
            let copyContent = NSMenuItem(title: "Copy content", action: #selector(contextCopySnippet), keyEquivalent: "")
            copyContent.target = self
            copyContent.representedObject = node.id
            menu.addItem(copyContent)

            let editSnippet = NSMenuItem(title: "Edit snippet…", action: #selector(contextEditSnippet), keyEquivalent: "")
            editSnippet.target = self
            editSnippet.representedObject = node.id
            menu.addItem(editSnippet)

            menu.addItem(NSMenuItem.separator())

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: Self.renameKey)
            rename.keyEquivalentModifierMask = []
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let archive = NSMenuItem(title: "Archive", action: #selector(contextDelete), keyEquivalent: Self.archiveKey)
            archive.target = self
            archive.representedObject = node.id
            menu.addItem(archive)
        }
    }

    @objc private func contextNewFolder() {
        onNewFolderRequested?(nil)
    }

    @objc private func contextNewTask() {
        onNewTaskRequested?(nil)
    }

    @objc private func contextNewSnippet() {
        onNewSnippetRequested?(nil)
    }

    @objc private func contextNewNestedFolder(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNewFolderRequested?(nodeId)
    }

    @objc private func contextRename() {
        guard let indexPath = contextIndexPath,
              let row = row(at: indexPath) else { return }
        beginInlineRename(nodeId: row.id, indexPath: indexPath)
    }

    @objc private func contextDelete(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodeDeleted?(nodeId)
    }

    @objc private func contextUnarchive(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodeUnarchived?(nodeId)
    }

    @objc private func contextPermanentlyDelete(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onNodePermanentlyDeleted?(nodeId)
    }

    @objc private func contextMoveToWorkspace(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: UUID],
              let nodeId = dict["nodeId"],
              let workspaceId = dict["workspaceId"] else { return }
        onNodeMovedToWorkspace?(nodeId, workspaceId)
    }

    @objc private func contextMoveToNewWorkspace(_ sender: NSMenuItem) {
        guard let nodeIds = sender.representedObject as? [UUID] else { return }
        onMoveToNewWorkspace?(nodeIds)
    }

    @objc private func contextMoveToNewFolder(_ sender: NSMenuItem) {
        guard let nodeIds = sender.representedObject as? [UUID] else { return }
        onMoveToNewFolder?(nodeIds)
    }

    @objc private func contextToggleTask(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onTaskToggled?(nodeId)
    }

    @objc private func contextSetDueDate(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onTaskDueDateRequested?(nodeId)
    }

    @objc private func contextClearDueDate(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onTaskDueDateCleared?(nodeId)
    }

    @objc private func contextCopySnippet(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onSnippetClicked?(nodeId)
    }

    @objc private func contextEditSnippet(_ sender: NSMenuItem) {
        guard let nodeId = sender.representedObject as? UUID else { return }
        onSnippetEditRequested?(nodeId)
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

    @objc private func contextEditUrl(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let nodeId = dict["nodeId"] as? UUID,
              let currentUrl = dict["currentUrl"] as? String else { return }

        let alert = NSAlert()
        alert.messageText = "Edit URL"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = currentUrl
        textField.isEditable = true
        textField.isSelectable = true
        alert.accessoryView = textField

        alert.window.initialFirstResponder = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newUrl = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newUrl.isEmpty, newUrl != currentUrl else { return }
            onLinkUrlEdited?(nodeId, newUrl)
        }
    }

    @objc private func contextOpenFolderLinks(_ sender: NSMenuItem) {
        guard let folderId = sender.representedObject as? UUID else { return }
        onOpenFolderLinks?(folderId)
    }

    private func countLinksInFolder(_ folder: Folder) -> Int {
        folder.children.flattenLinks().count
    }

    @objc private func bulkDelete() {
        guard selectedNodeIds.count > 0 else { return }
        onBulkNodesDeleted?(Array(selectedNodeIds))
        clearSelections()
    }
}

// MARK: - Supporting Types

private enum NodeListRowKind {
    case regular
    case archiveHeader(count: Int, isExpanded: Bool)
    case archived
}

private struct NodeListRow {
    let node: Node?
    let depth: Int
    let kind: NodeListRowKind
    let rowId: UUID

    init(node: Node, depth: Int, kind: NodeListRowKind = .regular) {
        self.node = node
        self.depth = depth
        self.kind = kind
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
    var onContextRequest: ((IndexPath?) -> Void)?
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

        onContextRequest?(indexPath)
        return menu
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
