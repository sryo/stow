import AppKit

/// The Elastic rail: a 52pt column of shapes. The Settings gear (page 0) heads the
/// workspace dots (the current one ringed), then one 38pt cell per top-level link or folder, tasks and
/// snippets folded into counted cells, and a round "+" that stows the front tab.
@MainActor
final class RailView: NSView {
    struct WorkspaceDot {
        let id: UUID
        let name: String
        let color: NSColor
    }

    var onSelectWorkspace: ((UUID) -> Void)?
    var onSettings: (() -> Void)?
    var onWorkspaceMenu: ((NSView) -> Void)?
    var onOpenLink: ((Link) -> Void)?
    var onOpenFolder: ((Folder) -> Void)?
    var onToggleTask: ((UUID) -> Void)?
    var onCopySnippet: ((UUID) -> Void)?
    var onStowTab: (() -> Void)?
    var onNodeMenu: ((Node, NSView) -> Void)?
    /// A link or folder dragged to a new place: its id and the `AppModel.moveNode` index.
    var onReorder: ((UUID, Int) -> Void)?
    /// A link or folder dropped on another workspace's dot.
    var onMoveToWorkspace: ((UUID, UUID) -> Void)?
    /// A workspace dot right-clicked: its id and the dot. Falls back to `onWorkspaceMenu`.
    var onWorkspaceContextMenu: ((UUID, NSView) -> Void)?
    /// Text dropped on the rail (a URL from a browser) and the `AppModel` index it lands at.
    var onDropText: ((String, Int) -> Void)?
    /// A snippet to edit, anchored to the rail view that asked.
    var onEditSnippet: ((UUID, NSView) -> Void)?
    /// A task whose due date to set, anchored to the rail view that asked.
    var onSetDueDate: ((UUID, NSView) -> Void)?
    var onNewTask: (() -> Void)?

    /// The tips beside resting cells and dots. Hide them when a rail flyout opens.
    let tips = RailTipController()
    /// The folder, tasks and snippets lists, beside the rail.
    let flyout = FlyoutListPresenter()

    private enum OpenList: Hashable { case folder(UUID), tasks, snippets }

    private let gear = RailGlyphButton(glyph: .gear)
    private let separator = NSView()
    private var scrollTop: NSLayoutConstraint!
    private let scrollView = NSScrollView()
    private let column = RailFlippedView()
    private let fab = RailFabButton()
    private var dotButtons: [RailDotButton] = []
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
    private var dropTargetDot: RailDotButton? {
        didSet {
            oldValue?.isDropTarget = false
            dropTargetDot?.isDropTarget = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gear.target = self
        gear.action = #selector(gearTapped)
        gear.toolTip = "Settings · ⌘, · or swipe right"
        gear.setAccessibilityLabel("Settings")
        addSubview(gear)

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
        fab.toolTip = "Stow the front browser tab"
        fab.setAccessibilityLabel("Stow this tab")
        addSubview(fab)

        registerForDraggedTypes([.URL, .string])

        scrollTop = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: SettingsRailLayout.dotsSeparatorY(count: 0) + 4)
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

    func configure(workspaces: [WorkspaceDot], selectedId: UUID?, colorId: WorkspaceColorId, items: [Node]) {
        colors = StowTheme.colors(for: colorId, tint: StowTheme.displayTint)
        let pageChanged = currentWorkspaceId != selectedId
        currentWorkspaceId = selectedId
        workspaceName = workspaces.first { $0.id == selectedId }?.name ?? ""
        itemIds = items.map(\.id)
        cancelDrag()
        tips.hide()

        dotButtons.forEach { $0.removeFromSuperview() }
        dotButtons = workspaces.enumerated().map { i, ws in
            let b = RailDotButton()
            b.workspaceId = ws.id
            b.fill = ws.color
            b.isCurrent = ws.id == selectedId
            b.tip = RailTipController.Tip(title: ws.name, detail: WorkspaceShortcut.label(position: i + 1))
            b.setAccessibilityLabel(ws.name)
            b.target = self
            b.action = #selector(dotTapped(_:))
            b.onRightClick = { [weak self, weak b] in
                guard let self, let b else { return }
                if let id = b.workspaceId, let menu = self.onWorkspaceContextMenu {
                    menu(id, b)
                } else {
                    self.onWorkspaceMenu?(b)
                }
            }
            b.onHover = { [weak self, weak b] inside in
                guard let self, let b, let tip = b.tip, !(inside && self.flyout.isOpen) else { return }
                self.tips.hover(b.tipId, view: b, tip: tip, inside: inside)
            }
            addSubview(b)
            return b
        }
        scrollTop.constant = SettingsRailLayout.dotsSeparatorY(count: workspaces.count) + 4
        // Place the new dots now: refreshHover() below reads the pointer against them.
        layoutDots()
        needsLayout = true

        rebuildCells(items: items)
        applyColors()
        applyOpenState()
        if pageChanged { flyout.closeAll() } else { refreshOpenList() }
        // ⌘1/⌘2 from a Tab-focused gear would otherwise carry its ring onto the next page.
        if pageChanged, let window, window.firstResponder === gear { window.makeFirstResponder(nil) }
        refreshHover()
    }

    /// The rail cell showing a top-level link or folder, for anchoring a flyout to it.
    func cellView(for nodeId: UUID) -> NSView? {
        cells.first { $0.node?.id == nodeId }
    }

    /// Re-reads which cell and dot sit under the pointer, after something moved them.
    func refreshHover() {
        cells.forEach { $0.refreshHoverState() }
        dotButtons.forEach { $0.refreshHover() }
    }

    @objc private func scrolled() {
        tips.hide()
        refreshHover()
    }

    // MARK: - Swiping

    /// Shows another workspace's items under the current dots, for the incoming side of a swipe.
    func previewItems(_ items: [Node]) {
        cancelDrag()
        flyout.closeAll()
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

    /// Each workspace dot's center, from the rail's top: where its Settings tile grows from.
    func dotCenters() -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]
        for (i, b) in dotButtons.enumerated() { if let id = b.workspaceId { result[id] = SettingsRailLayout.dotCenterY(at: i) } }
        return result
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let midX = round(bounds.midX)
        gear.frame = SettingsRailLayout.gearFrame.insetBy(dx: -4, dy: -4).offsetBy(dx: midX - 26, dy: 0)
        layoutDots()
        separator.frame = NSRect(x: midX - 10, y: SettingsRailLayout.dotsSeparatorY(count: dotButtons.count), width: 20, height: 1)
        column.frame.size.width = scrollView.contentSize.width
        for cell in cells { cell.frame.origin.x = (column.bounds.width - cell.frame.width) / 2 }
    }

    private func layoutDots() {
        let midX = round(bounds.midX)
        for (i, b) in dotButtons.enumerated() {
            let y = SettingsRailLayout.dotCenterY(at: i)
            b.frame = NSRect(x: midX - 10, y: y - 10, width: 20, height: 20)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        separator.layer?.backgroundColor = resolvedCGColor(colors.inkSecondary.withAlphaComponent(0.35))
        for b in dotButtons { b.ink = colors.inkPrimary; b.gap = colors.surface }
        gear.colors = colors
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
        if let target = dotDrop(at: point) {
            dropTargetDot = dotButtons.first { $0.workspaceId == target }
            // Fade the lifted copy so the swelling dot under it shows through.
            dragGhost?.alphaValue = 0.35
            dropBar.isHidden = true
            return
        }
        dropTargetDot = nil
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
            dropTargetDot = nil
            cell.alphaValue = 1
        }
        guard let id = cell.node?.id else { return }
        if let workspace = dotDrop(at: point) {
            onMoveToWorkspace?(id, workspace)
            return
        }
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
        dropTargetDot = nil
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

    private func dotDrop(at point: NSPoint) -> UUID? {
        guard let current = currentWorkspaceId else { return nil }
        let dots = dotButtons.compactMap { b in b.workspaceId.map { ($0, convert(b.dotRect, from: b)) } }
        return RailDrag.workspaceDrop(at: point, dots: dots, current: current)
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

    /// Opens the list for a folder, tasks or snippets cell beside the rail, or closes it
    /// when it's already open.
    private func showList(_ id: OpenList, from cell: RailCell) {
        tips.hide()
        guard let window, let content = listContent(for: id) else { return }
        flyout.toggle(id: id) {
            let list = FlyoutListView(title: content.title, detail: content.detail, sections: content.sections,
                                      footer: content.footer)
            let anchor = window.convertToScreen(cell.convert(cell.bounds, to: nil))
            let column = window.convertToScreen(convert(bounds, to: nil))
            flyout.show(list, id: id, anchor: anchor, edge: .beside(column: column),
                        topInset: FlyoutListView.Metrics.firstRowMidY, parent: window)
        }
    }

    private struct ListContent {
        var title: String
        var detail: String?
        var sections: [FlyoutListSection]
        var footer: [FlyoutListView.FooterButton] = []
    }

    private func listContent(for id: OpenList) -> ListContent? {
        switch id {
        case .folder(let folderId):
            guard let folder = topLevelFolder(folderId) else { return nil }
            let rows = FlyoutListModel.rows(for: folder, openKeys: openKeys)
            let openAll = FlyoutListView.FooterButton(title: "Open all  ⌥↩", style: .primary) { [weak self] in
                self?.onOpenFolder?(folder)
                self?.flyout.closeAll()
            }
            return ListContent(title: folder.name, detail: "\(rows.count)", sections: [FlyoutListSection(title: nil, rows: rows)],
                               footer: folder.children.flattenLinks().isEmpty ? [] : [openAll])
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
            case .pushFolder, .selectWorkspace:
                break
            }
        }
    }

    private func findLink(_ id: UUID) -> Link? {
        items.flattenLinks().first { $0.id == id }
    }

    @objc private func dotTapped(_ sender: RailDotButton) {
        guard let id = sender.workspaceId else { return }
        onSelectWorkspace?(id)
    }

    @objc private func fabTapped() { onStowTab?() }

    @objc private func gearTapped() { onSettings?() }
}

/// The lifted copy that follows the pointer; clicks go through it to the rail.
private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Workspace dot

/// 12pt workspace dot, drawn by the shared WorkspaceDot; the current one is ringed in ink.
/// It stays an NSButton (not BaseControl) so it keeps the button role and click handling
/// VoiceOver and `toolTip` readers expect; its tip shows through RailTipController.
private final class RailDotButton: NSButton {
    var workspaceId: UUID?
    var fill: NSColor = .gray { didSet { needsDisplay = true } }
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }
    var gap: NSColor = .clear { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var onRightClick: (() -> Void)?
    /// A dragged item is over this dot: it swells, like the mockup's drop state.
    var isDropTarget = false { didSet { needsDisplay = true } }
    private var isHovered = false {
        didSet {
            needsDisplay = true
            if isHovered != oldValue { onHover?(isHovered) }
        }
    }
    var onHover: ((Bool) -> Void)?
    /// The name and shortcut shown beside the dot after a dwell.
    var tip: RailTipController.Tip?
    let tipId = UUID()

    /// The tip's text. The system tooltip stays off: RailTipController shows the tip.
    override var toolTip: String? {
        get { tip?.text }
        set {}
    }

    /// The 12pt dot itself, centered in the button.
    var dotRect: NSRect { NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        // Unclipped, its visible rect (and so its hover area and tracking rect) is the
        // whole rail, and a pointer anywhere on it would hover every dot.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Current dot needs room for its two outer rings (2 + 1.5pt each side).
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    func refreshHover() {
        guard let window, !bounds.isEmpty else { isHovered = false; return }
        isHovered = visibleRect.intersection(bounds).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = isDropTarget ? 18 : (isHovered ? 15 : 12)
        let dot = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        WorkspaceDot.draw(in: dot, color: fill, style: isCurrent ? .ringed(ring: ink, gap: gap) : .plain)
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

    override func handleHoverStateChanged() { updateLook() }

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
