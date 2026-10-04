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

    private let gear = RailGlyphButton(glyph: .gear)
    private let separator = NSView()
    private var scrollTop: NSLayoutConstraint!
    private let scrollView = NSScrollView()
    private let column = FlippedView()
    private let fab = RailFabButton()
    private var dotButtons: [RailDotButton] = []
    private var cells: [RailCell] = []
    private var colors = StowTheme.colors(for: .defaultColor())
    private var openKeys: Set<String> = []
    private var currentWorkspaceId: UUID?
    private var itemIds: [UUID] = []
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

        fab.translatesAutoresizingMaskIntoConstraints = false
        fab.target = self
        fab.action = #selector(fabTapped)
        fab.toolTip = "Stow the front browser tab"
        fab.setAccessibilityLabel("Stow this tab")
        addSubview(fab)

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
        colors = StowTheme.colors(for: colorId, tint: StowTheme.preferredTint)
        currentWorkspaceId = selectedId
        itemIds = items.map(\.id)
        cancelDrag()

        dotButtons.forEach { $0.removeFromSuperview() }
        dotButtons = workspaces.enumerated().map { i, ws in
            let b = RailDotButton()
            b.workspaceId = ws.id
            b.fill = ws.color
            b.isCurrent = ws.id == selectedId
            b.toolTip = i < 9 ? "\(ws.name) · ⌃\(i + 1)" : ws.name
            b.setAccessibilityLabel(ws.name)
            b.target = self
            b.action = #selector(dotTapped(_:))
            b.onRightClick = { [weak self, weak b] in
                guard let self, let b else { return }
                self.onWorkspaceMenu?(b)
            }
            addSubview(b)
            return b
        }
        scrollTop.constant = SettingsRailLayout.dotsSeparatorY(count: workspaces.count) + 4
        needsLayout = true

        cells.forEach { $0.removeFromSuperview() }
        cells = []
        let active = items.filter { !$0.isArchived }
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
        let tasks = active.compactMap { if case .task(let t) = $0 { return t } else { return nil } }
        let snippets = active.compactMap { if case .snippet(let s) = $0 { return s } else { return nil } }
        var sectionStart: Int?
        if !tasks.isEmpty {
            sectionStart = sectionStart ?? cells.count
            cells.append(RailCell(kind: .tasks(tasks)))
        }
        if !snippets.isEmpty {
            sectionStart = sectionStart ?? cells.count
            cells.append(RailCell(kind: .snippets(snippets)))
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
            column.addSubview(cell)
            y += 40
        }
        column.frame = NSRect(x: 0, y: 0, width: 52, height: y + 6)
        applyColors()
        applyOpenState()
    }

    /// Marks links whose site is open in a browser, like the Dock's running indicator.
    func setOpenKeys(_ keys: Set<String>) {
        openKeys = keys
        applyOpenState()
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
        for (i, b) in dotButtons.enumerated() {
            let y = SettingsRailLayout.dotCenterY(at: i)
            b.frame = NSRect(x: midX - 10, y: y - 10, width: 20, height: 20)
        }
        separator.frame = NSRect(x: midX - 10, y: SettingsRailLayout.dotsSeparatorY(count: dotButtons.count), width: 20, height: 1)
        column.frame.size.width = scrollView.contentSize.width
        for cell in cells { cell.frame.origin.x = (column.bounds.width - cell.frame.width) / 2 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        separator.layer?.backgroundColor = resolvedCGColor(colors.inkSecondary.withAlphaComponent(0.35))
        for b in dotButtons { b.ink = colors.inkPrimary; b.ring = colors.inkSecondary; b.gap = colors.surface }
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
        dropBar.wantsLayer = true
        dropBar.layer?.cornerRadius = 1
        dropBar.layer?.backgroundColor = resolvedCGColor(colors.inkPrimary)
        dropBar.isHidden = true
        column.addSubview(dropBar)
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
        let y = slot < frames.count ? frames[slot].minY - 2 : frames[frames.count - 1].maxY + 1
        dropBar.frame = NSRect(x: 9, y: y, width: column.bounds.width - 18, height: 2)
        dropBar.isHidden = false
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

    private func dotDrop(at point: NSPoint) -> UUID? {
        guard let current = currentWorkspaceId else { return nil }
        let dots = dotButtons.compactMap { b in b.workspaceId.map { ($0, convert(b.dotRect, from: b)) } }
        return RailDrag.workspaceDrop(at: point, dots: dots, current: current)
    }

    private func activate(_ cell: RailCell) {
        switch cell.kind {
        case .link(let link, _):
            onOpenLink?(link)
        case .folder(let folder):
            showMenu(for: folder, from: cell)
        case .tasks(let tasks):
            let menu = NSMenu()
            for task in tasks {
                let item = NSMenuItem(title: task.title, action: #selector(taskPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = task.id
                item.state = task.isCompleted ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width + 4, y: 0), in: cell)
        case .snippets(let snippets):
            let menu = NSMenu()
            let header = NSMenuItem(title: "Copy snippet", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for snippet in snippets {
                let item = NSMenuItem(title: snippet.title, action: #selector(snippetPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = snippet.id
                item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width + 4, y: 0), in: cell)
        }
    }

    private func showMenu(for folder: Folder, from cell: NSView) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open All in \(folder.name)", action: #selector(folderOpenAll(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = folder.id
        menu.addItem(open)
        menu.addItem(.separator())
        addItems(folder.children.filter { !$0.isArchived }, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width + 4, y: 0), in: cell)
    }

    private func addItems(_ nodes: [Node], to menu: NSMenu) {
        for node in nodes {
            switch node {
            case .link(let link):
                let item = NSMenuItem(title: link.title, action: #selector(linkPicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = link.id
                item.image = RailCell.menuIcon(for: link)
                menu.addItem(item)
            case .folder(let folder):
                let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let sub = NSMenu()
                addItems(folder.children.filter { !$0.isArchived }, to: sub)
                item.submenu = sub
                menu.addItem(item)
            default:
                continue
            }
        }
    }

    private func findLink(_ id: UUID) -> Link? {
        func search(_ nodes: [Node]) -> Link? {
            for node in nodes {
                if case .link(let l) = node, l.id == id { return l }
                if case .folder(let f) = node, let hit = search(f.children) { return hit }
            }
            return nil
        }
        return search(cells.compactMap(\.node))
    }

    @objc private func dotTapped(_ sender: RailDotButton) {
        guard let id = sender.workspaceId else { return }
        onSelectWorkspace?(id)
    }

    @objc private func fabTapped() { onStowTab?() }

    @objc private func gearTapped() { onSettings?() }

    @objc private func linkPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let link = findLink(id) else { return }
        onOpenLink?(link)
    }

    @objc private func folderOpenAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        for cell in cells { if case .folder(let f) = cell.kind, f.id == id { onOpenFolder?(f) } }
    }

    @objc private func taskPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onToggleTask?(id)
    }

    @objc private func snippetPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onCopySnippet?(id)
    }
}

/// The lifted copy that follows the pointer; clicks go through it to the rail.
private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Workspace dot

/// 12pt workspace dot. The current one gets a gap ring and an ink ring around it.
private final class RailDotButton: NSButton {
    var workspaceId: UUID?
    var fill: NSColor = .gray { didSet { needsDisplay = true } }
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }
    var ring: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var gap: NSColor = .clear { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var onRightClick: (() -> Void)?
    /// A dragged item is over this dot: it swells, like the mockup's drop state.
    var isDropTarget = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    /// The 12pt dot itself, centered in the button.
    var dotRect: NSRect { NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
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

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = isDropTarget ? 18 : (isHovered ? 15 : 12)
        let dot = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        if isCurrent {
            ink.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -3.5, dy: -3.5)).fill()
            gap.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
        }
        fill.setFill()
        NSBezierPath(ovalIn: dot).fill()
        let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
        edge.lineWidth = 1.5
        (isCurrent ? ink : ring).setStroke()
        edge.stroke()
    }
}

// MARK: - Cell

private final class RailCell: NSView {
    enum Kind {
        case link(Link, letters: String)
        case folder(Folder)
        case tasks([TaskItem])
        case snippets([Snippet])
    }

    enum DragPhase { case began, moved, ended }

    let kind: Kind
    var onActivate: (() -> Void)?
    var onRightClick: (() -> Void)?
    /// Drag phases with the pointer in window coordinates; only links and folders drag.
    var onDrag: ((DragPhase, NSPoint) -> Void)?
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    // The window moves by its background; a cell press must drag the cell instead.
    override var mouseDownCanMoveWindow: Bool { false }

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }
    var isOpen = false { didSet { openDot.isHidden = !isOpen } }

    private let backgroundLayer = CALayer()
    private let iconLayer = CALayer()
    private let letterLabel = NSTextField(labelWithString: "")
    private let glyphView = NSImageView()
    private var mosaicLayers: [CALayer] = []
    private let openDot = NSView()
    private let badge = RailBadge()
    private var colors = StowTheme.colors(for: .defaultColor())
    private var isHovered = false { didSet { updateBackground() } }

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
            toolTip = "\(link.title)\n\(link.displayDomain ?? link.url)"
            setAccessibilityLabel(link.title)
            if let path = link.faviconPath, let image = NSImage(contentsOfFile: path) {
                iconLayer.contents = image
            } else {
                iconLayer.backgroundColor = Self.tileColor(for: link).cgColor
                letterLabel.stringValue = letters
                letterLabel.isHidden = false
            }
        case .folder(let folder):
            toolTip = "\(folder.name) · \(folder.children.count)"
            setAccessibilityLabel("\(folder.name), folder, \(folder.children.count) items")
            iconLayer.isHidden = true
            buildMosaic(folder)
        case .tasks(let tasks):
            let open = tasks.filter { !$0.isCompleted }.count
            toolTip = "Tasks · \(open) open"
            setAccessibilityLabel("Tasks, \(open) open")
            iconLayer.isHidden = true
            setGlyph("checklist")
            setBadge(open > 0 ? open : tasks.count)
        case .snippets(let snippets):
            toolTip = "Snippets · \(snippets.count)"
            setAccessibilityLabel("Snippets, \(snippets.count)")
            iconLayer.isHidden = true
            setGlyph("chevron.left.forwardslash.chevron.right")
            setBadge(snippets.count)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

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
        for (i, link) in links.enumerated() {
            let l = CALayer()
            l.frame = NSRect(x: 14 + CGFloat(i % 2) * (size + gap), y: 7 + CGFloat(i / 2) * (size + gap), width: size, height: size)
            l.cornerRadius = 3
            l.masksToBounds = true
            l.contentsGravity = .resizeAspect
            if let path = link.faviconPath, let image = NSImage(contentsOfFile: path) {
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
        updateBackground()
    }

    private func updateBackground() {
        backgroundLayer.backgroundColor = isHovered ? resolvedCGColor(colors.hover) : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
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

    // MARK: Letter tiles

    /// One letter per site, two where the first would collide (Linear "Li" next to LinkedIn "Lk"),
    /// or the capitals of a camel-cased name (GitHub "GH").
    static func assignLetters(_ links: [Link]) -> [UUID: String] {
        func name(_ link: Link) -> String {
            let host = (URL(string: link.url)?.host ?? link.title).replacingOccurrences(of: "www.", with: "")
            let title = link.title.split(separator: " ").first.map(String.init) ?? ""
            // Prefer the title's first word when it names the site; fall back to the host.
            return title.isEmpty ? (host.split(separator: ".").first.map(String.init) ?? host) : title
        }
        var result: [UUID: String] = [:]
        var firsts: [String: Int] = [:]
        for link in links { firsts[String(name(link).prefix(1)).uppercased(), default: 0] += 1 }
        for link in links {
            let n = name(link)
            let caps = n.filter(\.isUppercase)
            if caps.count >= 2 {
                result[link.id] = String(caps.prefix(2))
            } else if firsts[String(n.prefix(1)).uppercased(), default: 0] > 1 {
                result[link.id] = String(n.prefix(1)).uppercased() + String(n.dropFirst().prefix(1)).lowercased()
            } else {
                result[link.id] = String(n.prefix(1)).uppercased()
            }
        }
        return result
    }

    /// A stable, saturated color per host so a letter tile keeps its color everywhere.
    static func tileColor(for link: Link) -> NSColor {
        let host = URL(string: link.url)?.host ?? link.url
        var hash: UInt32 = 2166136261
        for byte in host.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.62, alpha: 1)
    }

    static func menuIcon(for link: Link) -> NSImage? {
        if let path = link.faviconPath, let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        let color = tileColor(for: link)
        let letter = assignLetters([link])[link.id] ?? "?"
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            return true
        }
    }
}

// MARK: - Fab

private final class RailFabButton: NSButton {
    private var colors = StowTheme.colors(for: .defaultColor())
    private var isHovered = false { didSet { updateLook() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        imagePosition = .imageOnly
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(colors: StowTheme.Colors) {
        self.colors = colors
        updateLook()
    }

    private func updateLook() {
        layer?.backgroundColor = resolvedCGColor(isHovered ? colors.inkPrimary : colors.hover)
        contentTintColor = isHovered ? colors.surface : colors.inkPrimary
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
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
