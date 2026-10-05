import AppKit

/// The Elastic rail: a 52pt column of shapes. The gear (the app sheet) heads the
/// workspace chip (the Tabline's element: the current workspace, a click for the list of
/// them all), then one 38pt cell per top-level link or folder, tasks and snippets folded
/// into counted cells, and a round "+" that stows the front tab.
@MainActor
final class RailView: NSView {
    struct WorkspaceEntry {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
        var identity: WorkspaceTileIdentity = .letter("?")
    }

    var onSelectWorkspace: ((UUID) -> Void)?
    /// The gear: the app sheet beside the rail.
    var onSettings: (() -> Void)?
    /// "New workspace…" from the workspace list's footer.
    var onNewWorkspace: (() -> Void)?
    var onOpenLink: ((Link) -> Void)?
    var onOpenFolder: ((Folder) -> Void)?
    var onToggleTask: ((UUID) -> Void)?
    var onCopySnippet: ((UUID) -> Void)?
    var onStowTab: (() -> Void)?
    var onNodeMenu: ((Node, NSView) -> Void)?
    /// A link or folder dragged to a new place: its id and the `AppModel.moveNode` index.
    var onReorder: ((UUID, Int) -> Void)?
    /// The workspace editor for a workspace, beside `view`: a right-click (or ⌃Return,
    /// ⇧F10, VoiceOver's Show Menu) on the chip or a row of its list, or the list's Edit
    /// Workspace….
    var onWorkspaceContextMenu: ((UUID, NSView) -> Void)?
    /// Text dropped on the rail (a URL from a browser) and the `AppModel` index it lands at.
    var onDropText: ((String, Int) -> Void)?
    /// A snippet to edit, anchored to the rail view that asked.
    var onEditSnippet: ((UUID, NSView) -> Void)?
    /// A task whose due date to set, anchored to the rail view that asked.
    var onSetDueDate: ((UUID, NSView) -> Void)?
    var onNewTask: (() -> Void)?

    /// The tips beside resting cells and the chip. Hide them when a rail flyout opens.
    let tips = RailTipController()
    /// The workspace, folder, tasks and snippets lists, beside the rail.
    let flyout = FlyoutListPresenter()

    private enum OpenList: Hashable { case workspaces, folder(UUID), tasks, snippets }

    private let gear = RailGlyphButton(glyph: .gear)
    private let gearTipId = UUID()
    /// The current workspace, under the gear; a click lists every workspace.
    let workspaceChip = RailWorkspaceChip()
    private let chipTipId = UUID()
    private var workspaces: [WorkspaceEntry] = []
    private let fabTipId = UUID()
    private let separator = NSView()
    private var scrollTop: NSLayoutConstraint!
    private let scrollView = NSScrollView()
    private let column = RailFlippedView()
    private let fab = RailFabButton()
    private var cells: [RailCell] = []
    private var colors = StowTheme.colors(for: .defaultColor())
    private var openKeys: Set<String> = []
    private var currentWorkspaceId: UUID?
    private var workspaceName = ""
    private var itemIds: [UUID] = []
    private var items: [Node] = []
    private var pocket = Pocket.Contents()
    private var dragGhost: NSImageView?
    private let dropBar = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gear.target = self
        gear.action = #selector(gearTapped)
        gear.railTip = .init(title: "Settings", detail: "⌘,")
        gear.setAccessibilityLabel("Settings")
        gear.onHover = { [weak self] inside in
            guard let self, let tip = self.gear.railTip, !(inside && self.flyout.isOpen) else { return }
            self.tips.hover(self.gearTipId, view: self.gear, tip: tip, inside: inside)
        }
        addSubview(gear)

        workspaceChip.target = self
        workspaceChip.action = #selector(chipTapped)
        workspaceChip.onRightClick = { [weak self] in
            guard let self, let id = self.currentWorkspaceId else { return }
            self.tips.hide()
            self.flyout.closeAll()
            self.onWorkspaceContextMenu?(id, self.workspaceChip)
        }
        workspaceChip.onHover = { [weak self] inside in
            guard let self, let tip = self.workspaceChip.railTip, !(inside && self.flyout.isOpen) else { return }
            self.tips.hover(self.chipTipId, view: self.workspaceChip, tip: tip, inside: inside)
        }
        addSubview(workspaceChip)

        separator.wantsLayer = true
        addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = column
        addSubview(scrollView)
        // Scrolling moves cells under a still pointer without any enter or exit.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        wireFlyout()

        fab.translatesAutoresizingMaskIntoConstraints = false
        fab.target = self
        fab.action = #selector(fabTapped)
        fab.railTip = .init(title: "Stow this tab", detail: "The front browser tab")
        fab.setAccessibilityLabel("Stow this tab")
        fab.onHover = { [weak self] inside in
            guard let self, let tip = self.fab.railTip, !(inside && self.flyout.isOpen) else { return }
            self.tips.hover(self.fabTipId, view: self.fab, tip: tip, inside: inside)
        }
        addSubview(fab)

        registerForDraggedTypes([.URL, .string])

        scrollTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: RailLayout.separatorY + 4)
        NSLayoutConstraint.activate([
            scrollTop,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: fab.topAnchor, constant: -8),
            fab.centerXAnchor.constraint(equalTo: centerXAnchor),
            fab.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            fab.widthAnchor.constraint(equalToConstant: 30),
            fab.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(workspaces: [WorkspaceEntry], selectedId: UUID?, colorId: WorkspaceColorId, items: [Node]) {
        colors = StowTheme.colors(for: colorId, tint: StowTheme.displayTint)
        let pageChanged = currentWorkspaceId != selectedId
        currentWorkspaceId = selectedId
        self.workspaces = workspaces
        workspaceName = workspaces.first { $0.id == selectedId }?.name ?? ""
        itemIds = items.map(\.id)
        cancelDrag()
        tips.hide()
        showChip(selectedId)
        needsLayout = true

        rebuildCells(items: items)
        applyColors()
        applyOpenState()
        if pageChanged, flyout.rootId as? OpenList != .workspaces { flyout.closeAll() } else { refreshOpenList() }
        // ⌘1/⌘2 from a Tab-focused gear would otherwise carry its ring onto the next page.
        if pageChanged, let window, window.firstResponder === gear { window.makeFirstResponder(nil) }
        refreshHover()
    }

    /// Puts a workspace on the chip: the current one, or the incoming one mid-swipe.
    private func showChip(_ id: UUID?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return workspaceChip.content = nil }
        let ws = workspaces[index]
        workspaceChip.content = .init(id: ws.id, name: ws.name, colorId: ws.colorId, identity: ws.identity)
        workspaceChip.railTip = .init(title: ws.name.isEmpty ? "Untitled" : ws.name, detail: WorkspaceShortcut.label(position: index + 1))
    }

    /// The gear, for anchoring the app sheet to it.
    var settingsGear: NSView { gear }

    /// The gear reads "on" while its sheet is open, and carries a warning dot when the
    /// sheet has a permission to ask for.
    func setSettings(open: Bool, badge: Bool) {
        gear.isOn = open
        gear.showsBadge = badge
        if open { tips.hide() }
    }

    /// The rail cell showing a top-level link or folder, for anchoring a flyout to it.
    func cellView(for nodeId: UUID) -> NSView? {
        cells.first { $0.node?.id == nodeId }
    }

    /// Re-reads which cell sits under the pointer, after something moved them.
    func refreshHover() {
        cells.forEach { $0.refreshHoverState() }
    }

    @objc private func scrolled() {
        tips.hide()
        refreshHover()
    }

    // MARK: - Swiping

    /// Shows another workspace's items, and that workspace on the chip, for the incoming
    /// side of a swipe.
    func previewItems(_ items: [Node], workspace: UUID? = nil) {
        cancelDrag()
        flyout.closeAll()
        if let workspace { showChip(workspace) }
        itemIds = items.map(\.id)
        rebuildCells(items: items)
        applyColors()
        applyOpenState()
        setItemsOffset(0)
    }

    /// A picture of the items as they are now, placed over them, for the outgoing side of a swipe.
    func snapshotItems() -> NSImageView? {
        let bounds = scrollView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = scrollView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        scrollView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let view = PassThroughImageView(image: image)
        view.imageScaling = .scaleNone
        view.wantsLayer = true
        view.frame = convert(scrollView.bounds, from: scrollView)
        addSubview(view)
        return view
    }

    /// Slides the items horizontally; 0 puts them back in place.
    func setItemsOffset(_ x: CGFloat) {
        scrollView.wantsLayer = true
        scrollView.layer?.transform = CATransform3DMakeTranslation(x, 0, 0)
    }

    private func rebuildCells(items: [Node]) {
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        self.items = items
        let active = items.unarchived()
        pocket = Pocket.collect(items)
        let letters = RailCell.assignLetters(active.compactMap { if case .link(let l) = $0 { return l } else { return nil } })
        for node in active {
            switch node {
            case .link(let link):
                cells.append(RailCell(kind: .link(link, letters: letters[link.id] ?? "?")))
            case .folder(let folder):
                cells.append(RailCell(kind: .folder(folder)))
            case .task, .snippet:
                continue
            }
        }
        // Tasks and snippets filed in folders count too, as in the Tabline's pocket.
        let tasks = pocket.tasks
        let snippets = pocket.snippets
        var sectionStart: Int?
        if !tasks.isEmpty {
            sectionStart = sectionStart ?? cells.count
            cells.append(RailCell(kind: .tasks(tasks)))
        }
        if !snippets.isEmpty {
            sectionStart = sectionStart ?? cells.count
            cells.append(RailCell(kind: .snippets(snippets)))
        }
        // An empty workspace shows a dashed "+" cell rather than a blank column. It takes drops.
        if cells.isEmpty, let copy = EmptyStateCopy.make(.emptyWorkspace, workspaceName: workspaceName, isTouch: false) {
            cells.append(RailCell(kind: .empty(RailTipController.Tip(title: copy.title, detail: copy.message))))
        }

        var y: CGFloat = 6
        for (i, cell) in cells.enumerated() {
            if i == sectionStart, i > 0 { y += 12 }
            cell.frame = NSRect(x: 0, y: y, width: 52, height: 38)
            cell.onActivate = { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.activate(cell)
            }
            cell.onRightClick = { [weak self, weak cell] in
                guard let self, let cell, let node = cell.node else { return }
                self.onNodeMenu?(node, cell)
            }
            cell.onDrag = { [weak self, weak cell] phase, windowPoint in
                guard let self, let cell else { return }
                self.handleDrag(cell, phase: phase, windowPoint: windowPoint)
            }
            cell.onHover = { [weak self, weak cell] inside in
                guard let self, let cell, !(inside && self.flyout.isOpen) else { return }
                self.tips.hover(cell.tipId, view: cell, tip: cell.tip, inside: inside)
            }
            column.addSubview(cell)
            y += 40
        }
        column.frame = NSRect(x: 0, y: 0, width: 52, height: y + 6)
        needsLayout = true
    }

    /// Marks links whose site is open in a browser, like the Dock's running indicator.
    func setOpenKeys(_ keys: Set<String>) {
        openKeys = keys
        flyout.openKeys = keys
        applyOpenState()
        if case .folder? = flyout.rootId as? OpenList { refreshOpenList() }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let midX = round(bounds.midX)
        gear.frame = RailLayout.gearFrame.insetBy(dx: -4, dy: -4).offsetBy(dx: midX - 26, dy: 0)
        workspaceChip.frame = RailLayout.chipFrame.offsetBy(dx: midX - 26, dy: 0)
        separator.frame = NSRect(x: midX - 10, y: RailLayout.separatorY, width: 20, height: 1)
        column.frame.size.width = scrollView.contentSize.width
        for cell in cells { cell.frame.origin.x = (column.bounds.width - cell.frame.width) / 2 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        separator.layer?.backgroundColor = resolvedCGColor(colors.inkSecondary.withAlphaComponent(0.35))
        gear.colors = colors
        workspaceChip.colors = colors
        for c in cells { c.apply(colors: colors) }
        fab.apply(colors: colors)
    }

    private func applyOpenState() {
        for cell in cells {
            guard case .link(let link, _) = cell.kind, let url = URL(string: link.url) else { continue }
            cell.isOpen = openKeys.contains(BrowserTabService.canonicalize(url))
        }
    }

    // MARK: - Dragging

    /// Links and folders, in rail order: the cells a drag can reorder.
    private var reorderableCells: [RailCell] { cells.filter { $0.node != nil } }

    private func handleDrag(_ cell: RailCell, phase: RailCell.DragPhase, windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        switch phase {
        case .began:
            tips.hide()
            beginDrag(cell)
            moveDrag(cell, to: point)
        case .moved:
            moveDrag(cell, to: point)
        case .ended:
            endDrag(cell, at: point)
        }
    }

    private func beginDrag(_ cell: RailCell) {
        cancelDrag()
        let ghost = PassThroughImageView(image: cell.snapshot())
        ghost.frame = convert(cell.bounds, from: cell)
        ghost.alphaValue = 0.9
        ghost.wantsLayer = true
        ghost.layer?.shadowOpacity = 0.25
        ghost.layer?.shadowRadius = 6
        ghost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(ghost)
        dragGhost = ghost
        cell.alphaValue = 0.3
        prepareDropBar()
    }

    /// The 2pt line between cells where a drop lands, hidden until a slot is shown.
    private func prepareDropBar() {
        dropBar.wantsLayer = true
        dropBar.layer?.cornerRadius = 1
        dropBar.layer?.backgroundColor = resolvedCGColor(colors.inkPrimary)
        dropBar.isHidden = true
        if dropBar.superview !== column { column.addSubview(dropBar) }
    }

    private func showDropBar(atSlot slot: Int, frames: [NSRect]) {
        guard !frames.isEmpty else { dropBar.isHidden = true; return }
        let y = slot < frames.count ? frames[slot].minY - 2 : frames[frames.count - 1].maxY + 1
        dropBar.frame = NSRect(x: 9, y: y, width: column.bounds.width - 18, height: 2)
        dropBar.isHidden = false
    }

    private func moveDrag(_ cell: RailCell, to point: NSPoint) {
        dragGhost?.frame.origin = NSPoint(x: point.x - cell.bounds.width / 2, y: point.y - cell.bounds.height / 2)
        dragGhost?.alphaValue = 0.9
        let frames = reorderableCells.map(\.frame)
        let columnPoint = column.convert(point, from: self)
        let slot = RailDrag.targetSlot(dragY: columnPoint.y, cellFrames: frames)
        guard let id = cell.node?.id, !frames.isEmpty,
              RailDrag.modelIndex(forSlot: slot, moving: id, railIds: reorderableCells.compactMap { $0.node?.id }, itemIds: itemIds) != nil else {
            dropBar.isHidden = true
            return
        }
        showDropBar(atSlot: slot, frames: frames)
    }

    private func endDrag(_ cell: RailCell, at point: NSPoint) {
        defer {
            dragGhost?.removeFromSuperview()
            dragGhost = nil
            dropBar.removeFromSuperview()
            cell.alphaValue = 1
        }
        guard let id = cell.node?.id else { return }
        let slot = RailDrag.targetSlot(dragY: column.convert(point, from: self).y, cellFrames: reorderableCells.map(\.frame))
        if let index = RailDrag.modelIndex(forSlot: slot, moving: id, railIds: reorderableCells.compactMap { $0.node?.id }, itemIds: itemIds) {
            onReorder?(id, index)
        }
    }

    /// Clears any drag still on screen, e.g. when the rail reloads mid-drag.
    private func cancelDrag() {
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        dropBar.removeFromSuperview()
        cells.forEach { $0.alphaValue = 1 }
    }

    // MARK: - Text dropped from a browser

    /// The empty workspace's "+" cell, which takes the whole drop.
    private var emptyCell: RailCell? {
        cells.first { if case .empty = $0.kind { return true } else { return false } }
    }

    private func textDropSlot(at point: NSPoint) -> Int {
        RailDrag.targetSlot(dragY: column.convert(point, from: self).y, cellFrames: reorderableCells.map(\.frame))
    }

    private func updateTextDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropText != nil, EmptyStateView.droppedText(from: sender)?.isEmpty == false else {
            endTextDrop()
            return []
        }
        tips.hide()
        if let empty = emptyCell {
            empty.isDropTarget = true
        } else {
            prepareDropBar()
            showDropBar(atSlot: textDropSlot(at: convert(sender.draggingLocation, from: nil)), frames: reorderableCells.map(\.frame))
        }
        return .copy
    }

    private func endTextDrop() {
        dropBar.removeFromSuperview()
        emptyCell?.isDropTarget = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateTextDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateTextDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { endTextDrop() }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { endTextDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endTextDrop() }
        guard let onDropText, let text = EmptyStateView.droppedText(from: sender), !text.isEmpty else { return false }
        let slot = textDropSlot(at: convert(sender.draggingLocation, from: nil))
        onDropText(text, RailDrag.textDropIndex(forSlot: slot, railIds: reorderableCells.compactMap { $0.node?.id }, itemIds: itemIds))
        return true
    }

    private func activate(_ cell: RailCell) {
        switch cell.kind {
        case .link(let link, _):
            flyout.closeAll()
            onOpenLink?(link)
        case .folder(let folder):
            showList(.folder(folder.id), from: cell)
        case .tasks:
            showList(.tasks, from: cell)
        case .snippets:
            showList(.snippets, from: cell)
        case .empty:
            flyout.closeAll()
            onStowTab?()
        }
    }

    // MARK: - Flyouts

    /// Opens the list for the workspace chip, or a folder, tasks or snippets cell, beside
    /// the rail, or closes it when it's already open.
    private func showList(_ id: OpenList, from anchorView: NSView) {
        tips.hide()
        guard let window, let content = listContent(for: id) else { return }
        flyout.toggle(id: id) {
            let list = FlyoutListView(title: content.title, detail: content.detail, sections: content.sections,
                                      footer: content.footer)
            let anchor = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            let column = window.convertToScreen(convert(bounds, to: nil))
            flyout.show(list, id: id, anchor: anchor, edge: .beside(column: column),
                        topInset: FlyoutListView.Metrics.firstRowMidY, parent: window)
        }
    }

    /// The chip's click: the workspace list the Tabline's chip opens.
    func showWorkspaceList() {
        showList(.workspaces, from: workspaceChip)
    }

    private struct ListContent {
        var title: String
        var detail: String?
        var sections: [FlyoutListSection]
        var footer: [FlyoutListView.FooterButton] = []
    }

    private func listContent(for id: OpenList) -> ListContent? {
        switch id {
        case .workspaces:
            guard !workspaces.isEmpty else { return nil }
            let sections = WorkspaceListFlyout.sections(workspaces: workspaces.map { ($0.id, $0.name, $0.colorId, $0.identity) },
                                                        current: currentWorkspaceId)
            let footer = WorkspaceListFlyout.footer(edit: { [weak self] in
                guard let self, let id = self.currentWorkspaceId else { return }
                self.flyout.closeAll()
                self.onWorkspaceContextMenu?(id, self.workspaceChip)
            }, newWorkspace: { [weak self] in
                self?.flyout.closeAll()
                self?.onNewWorkspace?()
            })
            return ListContent(title: WorkspaceListFlyout.title, detail: nil, sections: sections, footer: footer)
        case .folder(let folderId):
            guard let folder = topLevelFolder(folderId) else { return nil }
            let rows = FlyoutListModel.rows(for: folder, openKeys: openKeys)
            let openAll = FlyoutListView.FooterButton.openAll { [weak self] in
                self?.onOpenFolder?(folder)
                self?.flyout.closeAll()
            }
            return ListContent(title: folder.name, detail: "\(rows.count)", sections: [FlyoutListSection(title: nil, rows: rows)],
                               footer: folder.openableLinks.isEmpty ? [] : [openAll])
        case .tasks:
            guard !pocket.tasks.isEmpty else { return nil }
            let open = pocket.tasks.filter { !$0.isCompleted }.count
            return ListContent(title: "Tasks", detail: "\(open) open",
                               sections: [FlyoutListSection(title: nil, rows: FlyoutListModel.rows(for: pocket.tasks))])
        case .snippets:
            guard !pocket.snippets.isEmpty else { return nil }
            return ListContent(title: "Snippets", detail: "\(pocket.snippets.count)",
                               sections: [FlyoutListSection(title: nil, rows: FlyoutListModel.rows(for: pocket.snippets))])
        }
    }

    /// Re-reads the open list after the model changed: a task toggled, a row archived.
    private func refreshOpenList() {
        guard let id = flyout.rootId as? OpenList else { return }
        guard let content = listContent(for: id) else { flyout.closeAll(); return }
        flyout.refreshRoot(title: content.title, detail: content.detail, sections: content.sections)
    }

    private func topLevelFolder(_ id: UUID) -> Folder? {
        for node in items.unarchived() { if case .folder(let f) = node, f.id == id { return f } }
        return nil
    }

    /// The cell that opened the list, for anchoring an editor once the list closes.
    private func cell(for id: OpenList?) -> RailCell? {
        cells.first { cell in
            switch (cell.kind, id) {
            case (.tasks, .tasks?), (.snippets, .snippets?): return true
            case (.folder(let f), .folder(let folderId)?): return f.id == folderId
            default: return false
            }
        }
    }

    private func wireFlyout() {
        flyout.openKeys = openKeys
        flyout.onOpenAll = { [weak self] folder in self?.onOpenFolder?(folder) }
        flyout.onRowMenu = { [weak self] row, view in
            guard let self, let node = row.node else { return }
            self.onNodeMenu?(node, view)
        }
        // A workspace row's right-click: the editor where the row was, then the list gives way.
        flyout.onWorkspaceMenu = { [weak self] id, row in
            guard let self else { return }
            self.onWorkspaceContextMenu?(id, row)
            self.flyout.closeAll()
        }
        flyout.onClose = { [weak self] in
            guard let window = self?.window, window.isVisible else { return }
            window.makeKey()
        }
        flyout.onAction = { [weak self] action, _, _ in
            guard let self else { return }
            switch action {
            case .openLink(let id):
                if let link = self.findLink(id) { self.onOpenLink?(link) }
            case .toggleTask(let id):
                self.onToggleTask?(id)
            case .copySnippet(let id):
                self.onCopySnippet?(id)
            case .newTask:
                self.onNewTask?()
            case .setDueDate(let id):
                let anchor = self.cell(for: self.flyout.rootId as? OpenList) ?? self
                self.flyout.closeAll()
                self.onSetDueDate?(id, anchor)
            case .editSnippet(let id):
                let anchor = self.cell(for: self.flyout.rootId as? OpenList) ?? self
                self.flyout.closeAll()
                self.onEditSnippet?(id, anchor)
            case .selectWorkspace(let id):
                self.onSelectWorkspace?(id)
            case .pushFolder:
                break
            }
        }
    }

    private func findLink(_ id: UUID) -> Link? {
        items.flattenLinks().first { $0.id == id }
    }

    @objc private func chipTapped() { showWorkspaceList() }

    @objc private func fabTapped() { onStowTab?() }

    @objc private func gearTapped() { onSettings?() }
}

/// The lifted copy that follows the pointer; clicks go through it to the rail.
private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Workspace chip

/// The rail's workspace chip, the Tabline chip's counterpart: the current workspace's tile
/// (its mosaic, letter or symbol on its colour) over a small "▾". A click lists every
/// workspace; a right-click, ⌃Return, ⇧F10 or VoiceOver's Show Menu opens the editor.
final class RailWorkspaceChip: FocusableControl {
    struct Content: Equatable {
        var id: UUID
        var name: String
        var colorId: WorkspaceColorId
        var identity: WorkspaceTileIdentity
    }

    var content: Content? {
        didSet {
            guard content != oldValue else { return }
            tile.colorId = content?.colorId ?? .defaultColor()
            tile.identity = content?.identity ?? .letter("?")
            let name = content.map { $0.name.isEmpty ? "Untitled" : $0.name } ?? ""
            setAccessibilityLabel(content == nil ? "Workspaces" : "Workspace: \(name)")
            needsDisplay = true
        }
    }
    var colors = StowTheme.colors(for: .defaultColor()) { didSet { needsDisplay = true } }
    /// Shown beside the chip by the rail's RailTipController, in place of a system tooltip.
    var railTip: RailTipController.Tip?
    var onRightClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let tile = WorkspaceTileView()
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tile.setAccessibilityElement(false)
        addSubview(tile)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Workspaces")
        setAccessibilityHelp("Lists your workspaces. ⌃Return edits this one.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func handleHoverStateChanged() { needsDisplay = true; onHover?(isHovered) }
    override func handlePressedStateChanged() { needsDisplay = true }

    override func layout() {
        super.layout()
        let side = RailLayout.chipTile
        tile.frame = NSRect(x: round((bounds.width - side) / 2), y: 2, width: side, height: side)
        chevron.frame = NSRect(x: round(bounds.midX - 5), y: tile.frame.maxY + 1, width: 10, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isPressed {
            colors.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        chevron.contentTintColor = isHovered ? colors.inkPrimary : colors.inkSecondary
        if isFocused {
            SettingsColors.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    /// ⌃Return and ⇧F10 are the keyboard's right-click: the workspace editor.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .shift, .option, .command])
        let isControlReturn = flags == .control && (event.keyCode == 36 || event.keyCode == 76)
        let isShiftF10 = flags == .shift && event.keyCode == 109
        if isControlReturn || isShiftF10 {
            onRightClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onRightClick?()
        return true
    }
}

// MARK: - Cell

final class RailCell: BaseView {
    enum Kind {
        case link(Link, letters: String)
        case folder(Folder)
        case tasks([TaskItem])
        case snippets([Snippet])
        /// An empty workspace: the dashed "+" tile, with the empty state's words as its tip.
        case empty(RailTipController.Tip)
    }

    enum DragPhase { case began, moved, ended }

    let kind: Kind
    var onActivate: (() -> Void)?
    var onRightClick: (() -> Void)?
    /// Drag phases with the pointer in window coordinates; only links and folders drag.
    var onDrag: ((DragPhase, NSPoint) -> Void)?
    /// The pointer entered (true) or left; the rail shows `tip` after a dwell.
    var onHover: ((Bool) -> Void)?
    private(set) var tip = RailTipController.Tip(title: "")
    let tipId = UUID()
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
    var isOpen = false {
        didSet {
            openDot.isHidden = !isOpen
            updateAccessibilityLabel()
        }
    }
    /// The VoiceOver label before the open state is added.
    private var baseAccessibilityLabel = ""

    private let backgroundLayer = CALayer()
    private let iconLayer = CALayer()
    private let letterLabel = NSTextField(labelWithString: "")
    private let glyphView = NSImageView()
    private var mosaicLayers: [CALayer] = []
    private var folderPlate: CALayer?
    private let openDot = NSView()
    private let badge = RailBadge()
    private var addTile: RailGlyphButton?
    private var colors = StowTheme.colors(for: .defaultColor())
    /// Something dragged in would land here (the empty cell), so it lights like a hover.
    var isDropTarget = false { didSet { updateBackground() } }

    var node: Node? {
        switch kind {
        case .link(let l, _): return .link(l)
        case .folder(let f): return .folder(f)
        default: return nil
        }
    }

    override var isFlipped: Bool { true }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 52, height: 38))
        wantsLayer = true
        // The 38pt cell is centered in the 52pt rail; the open dot sits in its left margin.
        backgroundLayer.frame = NSRect(x: 7, y: 0, width: 38, height: 38)
        backgroundLayer.cornerRadius = 11
        backgroundLayer.cornerCurve = .continuous
        layer?.addSublayer(backgroundLayer)

        // The icon is a 24pt square inset 7pt; folders draw a 2×2 mosaic instead.
        let icon = NSRect(x: 14, y: 7, width: 24, height: 24)
        iconLayer.frame = icon
        iconLayer.cornerRadius = 6
        iconLayer.cornerCurve = .continuous
        iconLayer.masksToBounds = true
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)

        letterLabel.frame = icon.offsetBy(dx: 0, dy: 4.5)
        letterLabel.alignment = .center
        letterLabel.font = .systemFont(ofSize: 10.5, weight: .bold)
        letterLabel.textColor = .white
        letterLabel.isHidden = true
        addSubview(letterLabel)

        glyphView.frame = NSRect(x: 16, y: 9, width: 20, height: 20)
        glyphView.isHidden = true
        addSubview(glyphView)

        openDot.frame = NSRect(x: 6, y: 17, width: 4, height: 4)
        openDot.wantsLayer = true
        openDot.layer?.cornerRadius = 2
        openDot.isHidden = true
        addSubview(openDot)

        badge.isHidden = true
        addSubview(badge)

        switch kind {
        case .link(let link, let letters):
            tip = .init(title: link.title, detail: link.displayDomain ?? link.url)
            baseAccessibilityLabel = [link.title, "link", link.displayDomain].compactMap { $0 }.joined(separator: ", ")
            if let image = SiteGlyph.favicon(link.faviconPath) {
                iconLayer.contents = image
            } else {
                iconLayer.backgroundColor = Self.tileColor(for: link).cgColor
                letterLabel.stringValue = letters
                letterLabel.isHidden = false
            }
        case .folder(let folder):
            tip = .init(title: folder.name, detail: "\(folder.children.count) \(folder.children.count == 1 ? "item" : "items")")
            baseAccessibilityLabel = "\(folder.name), folder, \(folder.children.count) items"
            iconLayer.isHidden = true
            buildMosaic(folder)
        case .tasks(let tasks):
            let open = tasks.filter { !$0.isCompleted }.count
            tip = .init(title: "Tasks", detail: "\(open) open")
            baseAccessibilityLabel = "Tasks, \(open) open"
            iconLayer.isHidden = true
            setGlyph("checklist")
            setBadge(open > 0 ? open : tasks.count)
        case .snippets(let snippets):
            tip = .init(title: "Snippets", detail: "\(snippets.count)")
            baseAccessibilityLabel = "Snippets, \(snippets.count)"
            iconLayer.isHidden = true
            setGlyph("chevron.left.forwardslash.chevron.right")
            setBadge(snippets.count)
        case .empty(let emptyTip):
            tip = emptyTip
            baseAccessibilityLabel = emptyTip.title
            iconLayer.isHidden = true
            // The Settings rail's dashed "+" tile, drawn in the 38pt cell.
            let tile = RailGlyphButton(glyph: .addTile)
            tile.frame = NSRect(x: 7, y: 0, width: 38, height: 38)
            tile.target = self
            tile.action = #selector(addTileTapped)
            tile.setAccessibilityElement(false)
            addSubview(tile)
            addTile = tile
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        switch kind {
        case .link, .folder: setAccessibilityHelp("Drag to reorder or onto a workspace dot")
        case .tasks, .snippets: setAccessibilityHelp("Opens a list")
        case .empty: setAccessibilityHelp("Stows the front browser tab. You can also drop a link here.")
        }
        updateAccessibilityLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func addTileTapped() { onActivate?() }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(baseAccessibilityLabel + (isOpen ? ", open in browser" : ""))
    }

    private func setGlyph(_ symbol: String) {
        glyphView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        glyphView.isHidden = false
    }

    private func setBadge(_ count: Int) {
        badge.text = "\(count)"
        let w = badge.fittingWidth
        // Bottom-right corner of the glyph, like a Dock badge.
        badge.frame = NSRect(x: 37 - w / 2, y: 20, width: w, height: 15)
        badge.isHidden = false
    }

    private func buildMosaic(_ folder: Folder) {
        let links = folder.children.flattenLinks().prefix(4)
        let size: CGFloat = 11, gap: CGFloat = 2
        // One site sits large on a plate, so it reads as a folder without shrinking to 11pt.
        if links.count == 1 {
            let plate = CALayer()
            plate.frame = NSRect(x: 14, y: 7, width: 24, height: 24)
            plate.cornerRadius = 6
            plate.cornerCurve = .continuous
            layer?.addSublayer(plate)
            mosaicLayers.append(plate)
            folderPlate = plate
        }
        for (i, link) in links.enumerated() {
            let l = CALayer()
            l.frame = links.count == 1
                ? NSRect(x: 18, y: 11, width: 16, height: 16)
                : NSRect(x: 14 + CGFloat(i % 2) * (size + gap), y: 7 + CGFloat(i / 2) * (size + gap), width: size, height: size)
            l.cornerRadius = links.count == 1 ? 4 : 3
            l.masksToBounds = true
            l.contentsGravity = .resizeAspect
            if let image = SiteGlyph.favicon(link.faviconPath) {
                l.contents = image
            } else {
                l.backgroundColor = Self.tileColor(for: link).cgColor
            }
            layer?.addSublayer(l)
            mosaicLayers.append(l)
        }
        if links.isEmpty { setGlyph("folder") }
    }

    func apply(colors: StowTheme.Colors) {
        self.colors = colors
        openDot.layer?.backgroundColor = resolvedCGColor(colors.inkPrimary.withAlphaComponent(0.9))
        badge.fill = colors.inkPrimary
        badge.ink = colors.surface
        glyphView.contentTintColor = colors.inkPrimary
        folderPlate?.backgroundColor = resolvedCGColor(colors.inkPrimary.withAlphaComponent(0.1))
        addTile?.colors = colors
        updateBackground()
    }

    private func updateBackground() {
        // The dashed tile draws its own hover.
        let lit = isDropTarget || (isHovered && addTile == nil)
        backgroundLayer.backgroundColor = lit ? resolvedCGColor(colors.hover) : NSColor.clear.cgColor
    }

    // The rail hovers while the app is active, not only in the key window.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func handleHoverStateChanged() {
        updateBackground()
        onHover?(isHovered)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard node != nil, let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        if !isDragging {
            guard hypot(point.x - start.x, point.y - start.y) >= RailDrag.startThreshold else { return }
            isDragging = true
            onDrag?(.began, point)
        } else {
            onDrag?(.moved, point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; isDragging = false }
        if isDragging {
            onDrag?(.ended, event.locationInWindow)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate?()
        }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onRightClick?()
        return true
    }

    // MARK: Letter tiles

    /// Letters for the rail's sites, from the shared `SiteGlyph`.
    static func assignLetters(_ links: [Link]) -> [UUID: String] {
        SiteGlyph.assignLetters(links)
    }

    /// The site's tile color, from the shared `SiteGlyph`.
    static func tileColor(for link: Link) -> NSColor {
        SiteGlyph.tileColor(for: SiteGlyph.host(of: link.url))
    }

    static func menuIcon(for link: Link) -> NSImage? {
        SiteGlyph.menuImage(title: link.title, url: link.url, faviconPath: link.faviconPath)
    }
}

// MARK: - Fab

private final class RailFabButton: BaseControl {
    private var colors = StowTheme.colors(for: .defaultColor())
    private let glyph = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 15
        glyph.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        glyph.imageScaling = .scaleNone
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    func apply(colors: StowTheme.Colors) {
        self.colors = colors
        updateLook()
    }

    private func updateLook() {
        layer?.backgroundColor = resolvedCGColor(isHovered ? colors.inkPrimary : colors.hover)
        glyph.contentTintColor = isHovered ? colors.surface : colors.inkPrimary
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func handleHoverStateChanged() { updateLook(); onHover?(isHovered) }

    /// Shown by the rail's RailTipController instead of a system tooltip.
    var railTip: RailTipController.Tip? { didSet { setAccessibilityHelp(railTip?.text) } }
    var onHover: ((Bool) -> Void)?

    override func accessibilityPerformPress() -> Bool {
        performAction()
        return true
    }
}

// MARK: - Badge

private final class RailBadge: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var fill: NSColor = .labelColor { didSet { needsDisplay = true } }
    var ink: NSColor = .white { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    var fittingWidth: CGFloat {
        max(15, ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let s = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: ink])
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
