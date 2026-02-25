//
//  NodeListViewController.swift
//  Stow
//

import AppKit

/// Manages the node list collection view, including drag-drop and context menus
@MainActor
final class NodeListViewController: NSViewController {

    // MARK: - Properties

    fileprivate let collectionView = ContextMenuCollectionView()
    let scrollView = NSScrollView()
    private let dropIndicator = DropIndicatorView()
    private let listMetrics = ListMetrics()
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
    var onPinLink: ((UUID) -> Void)?
    var canPinLink: ((UUID) -> Bool)?
    var onMoveToNewWorkspace: (([UUID]) -> Void)?
    var onMoveToNewFolder: (([UUID]) -> Void)?

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
        didSet { updateShadows() }
    }

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
        let bgColor = workspaceColor.backgroundColor
        let opaqueColor = bgColor.cgColor
        let clearColor = bgColor.withAlphaComponent(0).cgColor

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
    func reloadData(with nodes: [Node], forceExpand: Bool, animated: Bool = true) {
        let newRows = buildVisibleRows(nodes: nodes, depth: 0, forceExpand: forceExpand)

        if !animated {
            visibleRows = newRows
            collectionView.reloadData()
            return
        }

        applyVisibleRows(newRows)
        handlePendingInlineRename()
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

    /// Shows a brief "Copied!" overlay on the row for the given node ID
    func showCopiedFeedback(for nodeId: UUID) {
        guard let index = visibleRows.firstIndex(where: { $0.id == nodeId }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) else { return }

        let label = NSTextField(labelWithString: "Copied!")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        label.isBezeled = false
        label.drawsBackground = true
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.sizeToFit()
        label.frame.size.width += 12
        label.frame.size.height += 4

        let rowView = item.view
        label.frame.origin = NSPoint(
            x: rowView.bounds.maxX - label.frame.width - 12,
            y: (rowView.bounds.height - label.frame.height) / 2
        )
        label.alphaValue = 0
        rowView.addSubview(label)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            label.animator().alphaValue = 1
        }, completionHandler: { [weak label] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak label] in
                guard let label else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    label.animator().alphaValue = 0
                }, completionHandler: { [weak label] in
                    MainActor.assumeIsolated {
                        label?.removeFromSuperview()
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
            collectionView.reloadData()
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
        }, completionHandler: nil)
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
        let item = collectionView.makeItem(withIdentifier: NodeCollectionViewItem.identifier, for: indexPath)
        guard let nodeItem = item as? NodeCollectionViewItem else { return item }
        guard let row = row(at: indexPath) else { return item }

        let isSelected = selectedNodeIds.contains(row.node.id)

        switch row.node {
        case .folder(let folder):
            let icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            icon?.isTemplate = true
            nodeItem.configure(
                title: folder.name,
                icon: icon,
                titleFont: listMetrics.folderTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: false,
                onDelete: nil,
                isSelected: isSelected
            )
        case .link(let link):
            let globeIconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let placeholder = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(globeIconConfig)
            placeholder?.isTemplate = true
            var iconToUse = placeholder
            var shouldFetch = true
            if let path = link.faviconPath,
               FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                image.isTemplate = false
                iconToUse = image
                shouldFetch = false
            }

            nodeItem.configure(
                title: link.title,
                icon: iconToUse,
                titleFont: listMetrics.linkTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: true,
                onDelete: { [weak self] in
                    self?.onNodeDeleted?(link.id)
                    self?.clearSelections()
                },
                isSelected: isSelected
            )

            if shouldFetch, let url = URL(string: link.url) {
                FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { _, path in
                    guard let path else { return }
                    NotificationCenter.default.post(
                        name: .init("UpdateLinkFavicon"),
                        object: nil,
                        userInfo: ["linkId": link.id, "path": path]
                    )
                }
            }
        case .task(let task):
            let iconName = task.isCompleted ? "checkmark.circle.fill" : "circle"
            let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            icon?.isTemplate = true
            nodeItem.configure(
                title: task.title,
                icon: icon,
                titleFont: listMetrics.linkTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: true,
                onDelete: { [weak self] in
                    self?.onNodeDeleted?(task.id)
                    self?.clearSelections()
                },
                isSelected: isSelected,
                isCompleted: task.isCompleted,
                dueDate: task.dueDate
            )
        case .snippet(let snippet):
            let icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            icon?.isTemplate = true
            let displayTitle = snippet.language != nil ? "\(snippet.title) (\(snippet.language!))" : snippet.title
            nodeItem.configure(
                title: displayTitle,
                icon: icon,
                titleFont: listMetrics.linkTitleFont,
                depth: row.depth,
                metrics: listMetrics,
                showDelete: true,
                onDelete: { [weak self] in
                    self?.onNodeDeleted?(snippet.id)
                    self?.clearSelections()
                },
                isSelected: isSelected
            )
        }

        // Configure swipe actions per node type
        nodeItem.swipeEnabled = !isSearchActive
        nodeItem.onSwipeLeft = { [weak self] in
            self?.onNodeDeleted?(row.node.id)
            self?.clearSelections()
        }

        switch row.node {
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

        return true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, let row = row(at: indexPath) else { return }
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
                self.toggleSelection(for: row.node.id)
                self.collectionView.deselectItems(at: indexPaths)
                return
            }

            // Clear selections on regular click
            if !self.selectedNodeIds.isEmpty {
                self.clearSelections()
            }

            switch row.node {
            case .folder(let folder):
                self.onFolderToggled?(folder.id, !folder.isExpanded)
            case .link(let link):
                self.onNodeSelected?(link.id)
            case .task(let task):
                self.onTaskToggled?(task.id)
            case .snippet(let snippet):
                self.onSnippetClicked?(snippet.id)
            }

            self.collectionView.deselectItems(at: indexPaths)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let row = row(at: indexPath) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(row.node.id.uuidString, forType: nodePasteboardType)
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
           case .folder = row.node,
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

        if indexPath.item < visibleRows.count, let row = row(at: indexPath) {
            switch row.node {
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
                if let location = findNodeLocation?(row.node.id) {
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
              let row = row(at: indexPath) else {
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

        let node = row.node

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

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            menu.addItem(delete)
        case .link(let link):
            let editUrl = NSMenuItem(title: "Edit URL…", action: #selector(contextEditUrl(_:)), keyEquivalent: "")
            editUrl.target = self
            editUrl.representedObject = ["nodeId": link.id, "currentUrl": link.url]
            menu.addItem(editUrl)

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)

            if let canPin = canPinLink, canPin(link.id) {
                let pinItem = NSMenuItem(title: "Pin this link", action: #selector(contextPinLink(_:)), keyEquivalent: "")
                pinItem.target = self
                pinItem.representedObject = link.id
                menu.addItem(pinItem)
            }

            addMoveToSubmenu()

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            menu.addItem(delete)
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

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            menu.addItem(delete)
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

            let rename = NSMenuItem(title: "Rename…", action: #selector(contextRename), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)

            addMoveToSubmenu()

            let delete = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            delete.target = self
            delete.representedObject = node.id
            menu.addItem(delete)
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

        // 4. Delete All
        let deleteItem = NSMenuItem(title: "Delete \(count) item\(count > 1 ? "s" : "")…", action: #selector(bulkDelete), keyEquivalent: "")
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

    @objc private func contextPinLink(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID else { return }
        onPinLink?(linkId)
    }

    private func countLinksInFolder(_ folder: Folder) -> Int {
        var count = 0
        for child in folder.children {
            switch child {
            case .link:
                count += 1
            case .folder(let nested):
                count += countLinksInFolder(nested)
            default:
                break
            }
        }
        return count
    }

    @objc private func bulkDelete() {
        let count = selectedNodeIds.count
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(count) item\(count == 1 ? "" : "s")?"
        alert.informativeText = "This will permanently delete the selected items. This cannot be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        if let deleteButton = alert.buttons.last {
            deleteButton.hasDestructiveAction = true
        }
        alert.alertStyle = .warning

        if alert.runModal() == .alertSecondButtonReturn {
            onBulkNodesDeleted?(Array(selectedNodeIds))
            clearSelections()
        }
    }
}

// MARK: - Supporting Types

private struct NodeListRow {
    let node: Node
    let depth: Int

    var id: UUID {
        node.id
    }
}

private final class DropIndicatorView: NSView {
    private let lineThickness: CGFloat = 2
    private let highlightCornerRadius: CGFloat = 8
    private let accentColor = NSColor.controlAccentColor

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
        layer?.backgroundColor = accentColor.cgColor
        layer?.borderWidth = 0
    }

    func showHighlight(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = highlightCornerRadius
        layer?.backgroundColor = accentColor.withAlphaComponent(0.12).cgColor
        layer?.borderColor = accentColor.cgColor
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
               parentVC.selectedNodeIds.contains(row.node.id),
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
}
