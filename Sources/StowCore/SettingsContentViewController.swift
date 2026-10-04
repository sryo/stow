//
//  SettingsContentViewController.swift
//  Stow
//

import AppKit

/// The Settings page at list and sidebar widths: Workspaces first, then the app sheet's
/// Window, Keyboard and Appearance groups (the same AppSheetView the rail shows behind
/// its sliders cell, in its page style), and a footer with the iCloud line, Import… and
/// the version. In the rail, Settings is SettingsRailController instead.
///
/// Layout is done with frames, top to bottom, so nothing here imposes a minimum width
/// on the container.
@MainActor
final class SettingsContentViewController: NSViewController {

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
    private let pageView = RailFlippedView()
    private let workspacesHeader = FlyoutLabel.section("Workspaces")
    private let workspaceCollectionView = WorkspaceListCollectionView()
    private let workspaceDropIndicator = WorkspaceDropIndicatorView()
    private let newWorkspaceRow = SettingsActionRow(title: "New workspace", symbolName: "plus")
    let sheet = AppSheetView(style: .page)
    private let footer = AppSheetFooterView(showsVersion: true)
    private var pendingRenameId: UUID?
    private var renamingWorkspaceId: UUID?
    private var needsReloadAfterRename = false
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
        pageView.addSubview(workspacesHeader)
        pageView.addSubview(workspaceCollectionView)
        pageView.addSubview(newWorkspaceRow)
        pageView.addSubview(sheet)
        sheet.onHeightChange = { [weak self] in self?.relayout() }
        sheet.onShowAllShortcuts = { [weak self] link in self?.toggleAllShortcuts(from: link) }
        footer.onImport = { NotificationCenter.default.post(name: .stowShowImport, object: nil) }
        view.addSubview(footer)
        reloadWorkspaces()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(scrollBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(opensInChanged), name: .workspaceOpensInChanged, object: nil)
        center.addObserver(self, selector: #selector(tintChanged), name: .stowTintModeChanged, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sheet.refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flyouts.closeAll()
    }

    // MARK: All shortcuts

    private let flyouts = FlyoutController()
    private let shortcutsPanel = FlyoutPanel()

    /// "All shortcuts…" opens the same flyout as in the rail, beside the window.
    private func toggleAllShortcuts(from link: NSView) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(link.convert(link.bounds, to: nil))
        flyouts.toggle(id: "allShortcuts") {
            let list = AllShortcutsView()
            flyouts.show(shortcutsPanel, id: "allShortcuts", content: list, size: list.preferredSize, anchor: anchor,
                         edge: .beside(column: window.frame), topInset: 24, parent: window)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
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
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.footerHeight),
        ])
    }

    private static let footerHeight: CGFloat = AppSheetFooterView.height + 6

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
        newWorkspaceRow.translatesAutoresizingMaskIntoConstraints = true
        newWorkspaceRow.target = self
        newWorkspaceRow.action = #selector(createWorkspace)
    }

    private static let workspaceItemId = NSUserInterfaceItemIdentifier("WorkspaceItem")

    // MARK: Layout

    /// The page reads as one column: past this width it stops growing and centres, so
    /// counts stay next to names and segmented controls keep their size.
    static let maxContentWidth: CGFloat = 420

    /// The column's horizontal extent in a page `width` wide.
    static func contentColumn(width: CGFloat) -> ClosedRange<CGFloat> {
        let column = min(width, maxContentWidth)
        let x = floor((width - column) / 2)
        return x...(x + column)
    }

    /// Workspaces, then the sheet's groups, top to bottom; the footer stays pinned below.
    private func relayout() {
        guard isViewLoaded else { return }
        let pageWidth = scrollView.contentSize.width
        guard pageWidth > 0 else { return }
        let column = Self.contentColumn(width: pageWidth)
        let x = column.lowerBound
        let width = column.upperBound - column.lowerBound
        let pad = SettingsMetrics.rowPadding
        var y: CGFloat = 4
        workspacesHeader.frame = NSRect(x: x + pad + 2, y: y, width: width - pad * 2, height: 12)
        y += 12 + 5
        let listHeight = CGFloat(appModel?.workspaces.count ?? 0) * SettingsMetrics.rowHeight
        workspaceCollectionView.frame = NSRect(x: x, y: y, width: width, height: listHeight)
        y += listHeight
        newWorkspaceRow.frame = NSRect(x: x, y: y, width: width, height: SettingsMetrics.rowHeight)
        y += SettingsMetrics.rowHeight + 2
        let sheetHeight = sheet.preferredHeight(forWidth: width)
        sheet.frame = NSRect(x: x, y: y, width: width, height: sheetHeight)
        y += sheetHeight + 12
        pageView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: y)
        let footerColumn = Self.contentColumn(width: view.bounds.width)
        footer.frame = NSRect(x: footerColumn.lowerBound + pad, y: view.isFlipped ? view.bounds.height - Self.footerHeight : 0,
                              width: footerColumn.upperBound - footerColumn.lowerBound - pad * 2, height: AppSheetFooterView.height)
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

    // MARK: Workspaces

    private func reloadWorkspaces() {
        guard isViewLoaded, let appModel else { return }
        if renamingWorkspaceId != nil {
            needsReloadAfterRename = true
            return
        }
        workspaceCollectionView.reloadData()
        sheet.previewColor = lastViewedWorkspace?.colorId ?? .defaultColor()
        relayout()
        if let id = pendingRenameId {
            pendingRenameId = nil
            beginInlineRename(id)
        }
        _ = appModel
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
        pendingRenameId = newId
        reloadWorkspaces()
    }

    private func beginInlineRename(_ id: UUID) {
        guard let appModel, let index = appModel.workspaces.firstIndex(id: id) else { return }
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
        WorkspaceDeletion.delete(id, model: appModel, in: window)
    }

    private func opensInChip(for workspace: Workspace) -> OpensInMenu.Display? {
        OpensInStore().choice(for: workspace.id).map(OpensInMenu.display)
    }

    @objc private func scrollBoundsChanged() {
        for item in workspaceCollectionView.visibleItems() {
            (item as? WorkspaceCollectionViewItem)?.refreshHoverState()
        }
    }

    @objc private func opensInChanged() {
        reloadWorkspaces()
    }

    @objc private func tintChanged() {
        workspaceCollectionView.reloadData()
    }

    @objc private func applicationDidBecomeActive() {
        AppPreferences.shared.applyPendingTabline()
        if AppPreferences.shared.applyPendingAttachment() {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Accessibility granted. Stow is attached to your browser.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        sheet.refresh()
    }
}

// MARK: - NSCollectionViewDataSource

extension SettingsContentViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        appModel?.workspaces.count ?? 0
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
            opensIn: opensInChip(for: workspace),
            itemCount: WorkspaceDeletion.itemCount(of: workspace),
            position: indexPath.item + 1,
            total: appModel.workspaces.count,
            canDelete: appModel.workspaces.count > 1,
            identity: WorkspaceTileIdentity.resolve(appModel.workspaces)[workspace.id]
        )
        workspaceItem.configure(workspace: workspace, content: content, actions: .init(
            showMenu: { [weak self] id, anchor in self?.showWorkspaceMenu(for: id, anchor: anchor) },
            showColorMenu: { [weak self] id, anchor in
                guard let self, let appModel = self.appModel else { return }
                self.popUp(WorkspaceMenu.makeColorMenu(for: id, model: appModel, presentingView: self.view), below: anchor)
            },
            showProfileMenu: { [weak self] id, anchor in
                guard let self else { return }
                self.popUp(WorkspaceMenu.makeOpensInMenu(for: id), below: anchor)
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
        guard let appModel, let index = appModel.workspaces.firstIndex(id: id) else { return }
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
        let index = min((proposedDropIndexPath.pointee as IndexPath).item, appModel?.workspaces.count ?? 0)
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

// MARK: - Collection view

/// The workspace list. The rows take keyboard focus themselves, so the list doesn't.
private final class WorkspaceListCollectionView: NSCollectionView {
    override var canBecomeKeyView: Bool { false }
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
