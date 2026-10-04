import AppKit

/// Settings in the 52pt rail: the ringed gear, the workspaces as 36pt identity tiles with
/// 9.5pt captions, a dashed "+" tile, and the quiet sliders cell in the bottom slot.
/// It only reports what happened; SettingsRailController decides what to do.
@MainActor
final class SettingsRailView: NSView {
    struct Tile: Equatable {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
        let identity: WorkspaceTileIdentity
        /// The full name and details, for VoiceOver.
        let accessibilityLabel: String
    }

    var onGear: (() -> Void)?
    var onTileClick: ((UUID) -> Void)?
    var onTileDoubleClick: ((UUID) -> Void)?
    var onTileMenu: ((UUID, NSView) -> Void)?
    var onTileHover: ((UUID, Bool) -> Void)?
    var onTileFocus: ((UUID?) -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onDragBegan: (() -> Void)?
    var onAdd: (() -> Void)?
    var onQuiet: (() -> Void)?
    /// The pointer entered (true) or left the gear, "+" or sliders cell, with its tip.
    var onGlyphHover: ((NSView, RailTipController.Tip, Bool) -> Void)?
    var onBackgroundClick: (() -> Void)?

    private(set) var tiles: [Tile] = []
    private var rows: [UUID: TileRowView] = [:]
    private let gear = RailGlyphButton(glyph: .gear)
    private let separator = NSView()
    private let scrollView = NSScrollView()
    private let column = RailFlippedView()
    private let addTile = RailGlyphButton(glyph: .addTile)
    private let quietSeparator = NSView()
    private let quiet = RailGlyphButton(glyph: .sliders)
    private let dropBar = NSView()
    private var colors = StowTheme.colors(for: .settingsBackground)
    private var cameFrom: UUID?
    private var selected: UUID?
    /// Room above the first tile for its selection ring, inside the scroll view.
    private static let ringRoom: CGFloat = 4
    private var pendingClick: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        gear.isOn = true
        gear.target = self
        gear.action = #selector(gearTapped)
        addSubview(gear)

        separator.wantsLayer = true
        addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = column
        scrollView.contentView.drawsBackground = false
        addSubview(scrollView)

        addTile.target = self
        addTile.action = #selector(addTapped)
        addTile.railTip = .init(title: "New workspace")
        addTile.setAccessibilityLabel("New workspace")
        column.addSubview(addTile)

        dropBar.wantsLayer = true
        dropBar.layer?.cornerRadius = 1
        dropBar.isHidden = true
        column.addSubview(dropBar)

        quietSeparator.wantsLayer = true
        addSubview(quietSeparator)
        quiet.target = self
        quiet.action = #selector(quietTapped)
        quiet.railTip = .init(title: "App settings")
        quiet.setAccessibilityLabel("App settings")
        addSubview(quiet)
        for glyph in [gear, addTile, quiet] {
            glyph.onHover = { [weak self, weak glyph] inside in
                guard let self, let glyph, let tip = glyph.railTip else { return }
                self.onGlyphHover?(glyph, tip, inside)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configure

    func configure(tiles: [Tile], cameFrom: UUID?, selected: UUID?, sheetOpen: Bool, badge: Bool, returnName: String?) {
        self.cameFrom = cameFrom
        self.selected = selected
        let ids = Set(tiles.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        for tile in tiles {
            let row = rows[tile.id] ?? makeRow()
            rows[tile.id] = row
            row.tile = tile
        }
        self.tiles = tiles
        gear.railTip = .init(title: returnName.map { "Back to \($0)" } ?? "Settings", detail: "⌘,")
        gear.setAccessibilityLabel(returnName.map { "Leave Settings, back to \($0)" } ?? "Settings")
        quiet.isOn = sheetOpen
        quiet.showsBadge = badge
        quiet.setAccessibilityValue(badge ? "Needs Accessibility access" : nil)
        layoutTiles(animated: false)
        applyColors()
        linkKeyViews()
    }

    /// Tab walks the tiles in order, then "+", the sliders cell and the gear.
    private func linkKeyViews() {
        let ordered: [NSView] = tiles.compactMap { rows[$0.id] } + [addTile, quiet, gear]
        nextKeyView = ordered.first
        for (view, next) in zip(ordered, ordered.dropFirst() + [ordered[0]]) { view.nextKeyView = next }
    }

    /// Takes the keyboard on entering Settings, so Tab lands on the first tile.
    override var acceptsFirstResponder: Bool { true }

    func takeKeyboard() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: if let first = tiles.first { focusTile(first.id) }
        default: interpretKeyEvents([event])
        }
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

    fileprivate func focusNeighbor(of row: TileRowView, step: Int) {
        guard let id = row.tile?.id, let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let next = index + step
        guard tiles.indices.contains(next) else { return }
        focusTile(tiles[next].id)
    }

    private func makeRow() -> TileRowView {
        let row = TileRowView()
        row.owner = self
        column.addSubview(row, positioned: .below, relativeTo: dropBar)
        return row
    }

    func setColors(_ colors: StowTheme.Colors) {
        self.colors = colors
        applyColors()
    }

    private func applyColors() {
        separator.layer?.backgroundColor = flyoutCG(colors.inkSecondary.withAlphaComponent(0.35))
        quietSeparator.layer?.backgroundColor = flyoutCG(colors.inkSecondary.withAlphaComponent(0.35))
        dropBar.layer?.backgroundColor = flyoutCG(colors.inkPrimary)
        for button in [gear, addTile, quiet] { button.colors = colors }
        for (id, row) in rows {
            row.apply(colors: colors, isCameFrom: id == cameFrom, isSelected: id == selected)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let L = SettingsRailLayout.self
        gear.frame = L.gearFrame.insetBy(dx: -4, dy: -4)
        separator.frame = NSRect(x: 16, y: L.separatorY, width: 20, height: 1)
        scrollView.frame = NSRect(x: 0, y: L.listTop - Self.ringRoom, width: bounds.width,
                                  height: L.listHeight(railHeight: bounds.height) + Self.ringRoom)
        quietSeparator.frame = NSRect(x: 16, y: bounds.height - L.quietSeparatorFromBottom, width: 20, height: 1)
        quiet.frame = L.quietCellFrame(railHeight: bounds.height)
        layoutTiles(animated: false)
    }

    /// Places rows in `order` (the live drag preview), or in model order.
    private func layoutTiles(animated requested: Bool, order: [UUID]? = nil, skipping dragged: UUID? = nil) {
        let animated = requested && !RailMotion.reduceMotion
        let order = order ?? tiles.map(\.id)
        let x = round((bounds.width - SettingsRailLayout.railWidth) / 2)
        let apply = {
            for (index, id) in order.enumerated() where id != dragged {
                guard let row = self.rows[id] else { continue }
                let frame = SettingsRailLayout.rowFrame(at: index).offsetBy(dx: x, dy: Self.ringRoom)
                if animated { row.animator().frame = frame } else { row.frame = frame }
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
        addTile.frame = SettingsRailLayout.addTileFrame(count: tiles.count).offsetBy(dx: x, dy: Self.ringRoom)
        let height = max(SettingsRailLayout.contentHeight(count: tiles.count) + Self.ringRoom + 8, scrollView.contentSize.height)
        column.frame = NSRect(x: 0, y: 0, width: max(bounds.width, 52), height: height)
    }

    // MARK: Anchors

    /// The tile's frame in screen coordinates, for placing the editor and the tip.
    func screenFrame(ofTile id: UUID) -> NSRect? {
        guard let row = rows[id], let window else { return nil }
        let rect = row.convert(row.tileFrame, to: nil)
        return window.convertToScreen(rect)
    }

    func screenFrameOfQuietCell() -> NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(quiet.convert(quiet.bounds, to: nil))
    }

    func scrollTileToVisible(_ id: UUID) {
        guard let row = rows[id] else { return }
        column.scrollToVisible(row.frame.insetBy(dx: 0, dy: -8))
    }

    func focusTile(_ id: UUID) {
        guard let row = rows[id] else { return }
        scrollTileToVisible(id)
        window?.makeFirstResponder(row)
    }

    // MARK: Actions

    @objc private func gearTapped() { onGear?() }
    @objc private func addTapped() { onAdd?() }
    @objc private func quietTapped() { onQuiet?() }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    fileprivate func rowHovered(_ row: TileRowView, _ inside: Bool) {
        guard let id = row.tile?.id else { return }
        onTileHover?(id, inside)
    }

    fileprivate func rowFocused(_ row: TileRowView, _ focused: Bool) {
        onTileFocus?(focused ? row.tile?.id : nil)
    }

    fileprivate func rowActivated(_ row: TileRowView) {
        guard let id = row.tile?.id else { return }
        onTileClick?(id)
    }

    fileprivate func rowMenu(_ row: TileRowView) {
        guard let id = row.tile?.id else { return }
        onTileMenu?(id, row)
    }

    /// Click, double-click or drag. A single click waits 180ms so a double-click can
    /// take over; a drag starts after 4pt and reorders on release.
    fileprivate func track(_ row: TileRowView, from event: NSEvent) {
        guard let window, let tile = row.tile, let fromIndex = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onTileDoubleClick?(tile.id)
            return
        }
        let start = column.convert(event.locationInWindow, from: nil)
        let grab = start.y - row.frame.minY
        var dragging = false
        var target = fromIndex
        let ids = tiles.map(\.id)

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = column.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            if !dragging {
                guard TileReorder.hasStarted(dy: point.y - start.y) else { continue }
                dragging = true
                pendingClick?.cancel()
                onDragBegan?()
                row.isLifted = true
                column.addSubview(row, positioned: .above, relativeTo: nil)
            }
            let tileTop = TileReorder.clampedTileTop(point.y - grab - Self.ringRoom, count: tiles.count)
            row.frame.origin.y = tileTop + Self.ringRoom
            let newTarget = TileReorder.targetIndex(tileTop: tileTop, count: tiles.count)
            dropBar.isHidden = false
            dropBar.frame = NSRect(x: row.frame.minX + 12, y: TileReorder.dropIndicatorY(to: newTarget) + Self.ringRoom, width: 28, height: 2)
            if newTarget != target {
                target = newTarget
                layoutTiles(animated: true, order: TileReorder.order(ids, moving: tile.id, to: target), skipping: tile.id)
            }
            column.autoscroll(with: next)
        }

        if dragging {
            row.isLifted = false
            dropBar.isHidden = true
            if let to = TileReorder.move(from: fromIndex, to: target) {
                tiles = TileReorder.order(tiles, moving: tile, to: to)
                layoutTiles(animated: true)
                onReorder?(tile.id, to)
            } else {
                layoutTiles(animated: true)
            }
            return
        }
        let work = DispatchWorkItem { [weak self, weak row] in
            guard let self, let row else { return }
            self.pendingClick = nil
            self.rowActivated(row)
        }
        pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    // MARK: Grow and shrink

    static let morphDuration: CFTimeInterval = 0.42
    static let morphTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// The dots grow into tiles: each tile starts as a 12pt circle at its dot's height
    /// (rail coordinates) and settles into place while its caption fades in.
    func animateIn(dotCenters: [UUID: CGFloat]) {
        layoutSubtreeIfNeeded()
        for (id, row) in rows {
            guard let dotY = dotCenters[id] else { continue }
            row.morph(from: dotY - tileCenterY(row), duration: Self.morphDuration, reverse: false, completion: nil)
        }
        for view in [addTile, quiet, quietSeparator, separator] { fade(view, from: 0, to: 1, duration: Self.morphDuration) }
    }

    /// The reverse: tiles shrink back toward their dots, then `completion` runs.
    func animateOut(dotCenters: [UUID: CGFloat], completion: @escaping () -> Void) {
        let duration: CFTimeInterval = 0.38
        var remaining = 0
        for (id, row) in rows {
            guard let dotY = dotCenters[id] else { continue }
            remaining += 1
            row.morph(from: dotY - tileCenterY(row), duration: duration, reverse: true) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
        for view in [addTile, quiet, quietSeparator] { fade(view, from: 1, to: 0, duration: duration * 0.7) }
        if remaining == 0 { completion() }
    }

    func resetMorph() {
        for row in rows.values { row.resetMorph() }
        for view in [addTile, quiet, quietSeparator, separator] { view.layer?.removeAllAnimations(); view.alphaValue = 1 }
    }

    private func tileCenterY(_ row: TileRowView) -> CGFloat {
        convert(NSPoint(x: 0, y: row.tileFrame.midY), from: row).y
    }

    private func fade(_ view: NSView, from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        view.alphaValue = from
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = Self.morphTiming
            view.animator().alphaValue = to
        }
    }
}

// MARK: - Tile row

/// One workspace: its tile, the caption under it and, for the workspace you came from,
/// a 4pt dot in the left margin.
@MainActor
private final class TileRowView: RailFlippedView {
    weak var owner: SettingsRailView?
    private let tileView = WorkspaceTileView()
    private let caption = NSTextField(labelWithString: "")
    private let cameFromDot = NSView()
    private var isHovered = false { didSet { refreshTile() } }
    private var isFocused = false { didSet { refreshTile() } }
    var isLifted = false { didSet { refreshTile() } }
    private var colors = StowTheme.colors(for: .settingsBackground)
    private var isSelected = false

    var tile: SettingsRailView.Tile? {
        didSet {
            guard let tile else { return }
            tileView.colorId = tile.colorId
            tileView.identity = tile.identity
            caption.stringValue = SettingsRailLayout.caption(tile.name)
            setAccessibilityLabel(tile.accessibilityLabel)
        }
    }

    /// The 36pt tile within the row.
    var tileFrame: NSRect { NSRect(x: SettingsRailLayout.tileX, y: 0, width: 36, height: 36) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 52, height: SettingsRailLayout.rowHeight))
        wantsLayer = true
        tileView.ringInset = 3.5
        tileView.frame = tileFrame.insetBy(dx: -3.5, dy: -3.5)
        addSubview(tileView)
        caption.font = SettingsRailLayout.captionFont
        caption.alignment = .center
        caption.lineBreakMode = .byClipping
        // A label insets its text 2pt each side, so the field spans the row to give the
        // caption its full 48pt.
        caption.frame = SettingsRailLayout.captionFrame(at: 0).insetBy(dx: -2, dy: 0)
        caption.setAccessibilityElement(false)
        addSubview(caption)
        cameFromDot.wantsLayer = true
        cameFromDot.layer?.cornerRadius = 2
        cameFromDot.frame = SettingsRailLayout.cameFromDotFrame(at: 0)
        addSubview(cameFromDot)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Click to edit, double-click to open. Drag to reorder.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(colors: StowTheme.Colors, isCameFrom: Bool, isSelected: Bool) {
        self.colors = colors
        self.isSelected = isSelected
        cameFromDot.isHidden = !isCameFrom
        cameFromDot.layer?.backgroundColor = flyoutCG(colors.inkPrimary.withAlphaComponent(0.9))
        caption.textColor = isSelected ? colors.inkPrimary : colors.inkSecondary
        caption.isHidden = isLifted
        setAccessibilityValue(isCameFrom ? "Where you came from" : nil)
        refreshTile()
    }

    private func refreshTile() {
        tileView.showsRing = isSelected || isFocused
        tileView.ringInk = isFocused && !isSelected ? SettingsColors.accent : colors.inkPrimary
        tileView.ringGap = colors.surface
        // Hover grows the tile 4% and a lifted tile 10%, inside the room kept for the ring.
        let grow: CGFloat = isLifted ? 1.8 : (isHovered ? 0.72 : 0)
        tileView.ringInset = 3.5 - grow
        caption.isHidden = isLifted
        tileView.layer?.shadowOpacity = isLifted ? 0.28 : 0
        tileView.layer?.shadowRadius = 11
        tileView.layer?.shadowOffset = CGSize(width: 0, height: -10)
    }

    // MARK: Morph

    func morph(from dy: CGFloat, duration: CFTimeInterval, reverse: Bool, completion: (() -> Void)?) {
        guard let layer = tileView.layer else { completion?(); return }
        let b = layer.bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        // The backing layer's anchor is its origin, so scale about the tile's center.
        var shrunk = CATransform3DMakeTranslation(c.x, c.y, 0)
        // dy is measured top-down; flip it when the layer tree's y runs upward.
        let yDown = layer.superlayer?.contentsAreFlipped() ?? true
        shrunk = CATransform3DTranslate(shrunk, 0, yDown ? dy : -dy, 0)
        shrunk = CATransform3DScale(shrunk, 1.0 / 3.0, 1.0 / 3.0, 1)
        shrunk = CATransform3DTranslate(shrunk, -c.x, -c.y, 0)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = reverse ? CATransform3DIdentity : shrunk
        transform.toValue = reverse ? shrunk : CATransform3DIdentity
        transform.duration = duration
        transform.timingFunction = SettingsRailView.morphTiming
        transform.fillMode = .forwards
        transform.isRemovedOnCompletion = !reverse
        layer.add(transform, forKey: "morph")
        CATransaction.commit()

        tileView.radiusOverride = nil
        let from: CGFloat = reverse ? 1 : 0, to: CGFloat = reverse ? 0 : 1
        caption.alphaValue = from
        cameFromDot.alphaValue = from
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reverse ? duration * 0.5 : duration
            context.timingFunction = SettingsRailView.morphTiming
            caption.animator().alphaValue = to
            cameFromDot.animator().alphaValue = to
        }
    }

    func resetMorph() {
        tileView.layer?.removeAnimation(forKey: "morph")
        caption.alphaValue = 1
        cameFromDot.alphaValue = 1
    }

    // MARK: Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window moves by its background; dragging a tile reorders instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        owner?.rowHovered(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        owner?.rowHovered(self, false)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.track(self, from: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.rowMenu(self)
    }

    override var acceptsFirstResponder: Bool { NSApp.currentEvent?.type != .leftMouseDown }
    override var canBecomeKeyView: Bool { true }

    override func drawFocusRingMask() {}
    override var focusRingMaskBounds: NSRect { .zero }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        owner?.rowFocused(self, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        owner?.rowFocused(self, false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: owner?.rowActivated(self)
        case 125: owner?.focusNeighbor(of: self, step: 1)
        case 126: owner?.focusNeighbor(of: self, step: -1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.rowActivated(self)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        owner?.rowMenu(self)
        return true
    }
}

// MARK: - Glyph buttons

/// The rail's small drawn controls: the gear, the dashed "+" tile and the sliders cell.
@MainActor
final class RailGlyphButton: FocusableControl {
    enum Glyph { case gear, addTile, sliders }

    let glyph: Glyph
    var colors = StowTheme.colors(for: .settingsBackground) { didSet { needsDisplay = true } }
    /// The gear while Settings is current; the sliders cell while its sheet is open.
    var isOn = false { didSet { needsDisplay = true } }
    var showsBadge = false { didSet { needsDisplay = true } }
    /// Shown beside the button by the rail's RailTipController, in place of a system
    /// tooltip; VoiceOver reads it as help.
    var railTip: RailTipController.Tip? { didSet { setAccessibilityHelp(railTip?.text) } }
    var onHover: ((Bool) -> Void)?

    init(glyph: Glyph) {
        self.glyph = glyph
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func handleHoverStateChanged() { needsDisplay = true; onHover?(isHovered) }
    override func handlePressedStateChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        switch glyph {
        case .gear: drawGear()
        case .addTile: drawAddTile()
        case .sliders: drawSliders()
        }
        if isFocused {
            SettingsColors.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func drawGear() {
        // 14pt circle centered in the button; "on" adds a 2pt gap and a 1.5pt ink ring.
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if isOn {
            colors.inkPrimary.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 10.5, y: c.y - 10.5, width: 21, height: 21)).fill()
            colors.surface.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
        }
        let scale: CGFloat = (isHovered ? 1.2 : 1) * 12 / 16
        let ink = isOn || isHovered ? colors.inkPrimary : colors.inkSecondary
        ink.setStroke()
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c.x + (x - 8) * scale, y: c.y + (y - 8) * scale) }
        path.appendOval(in: NSRect(x: c.x - 2.2 * scale, y: c.y - 2.2 * scale, width: 4.4 * scale, height: 4.4 * scale))
        let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (8, 1.6, 8, 3.4), (8, 12.6, 8, 14.4), (1.6, 8, 3.4, 8), (12.6, 8, 14.4, 8),
            (3.5, 3.5, 4.8, 4.8), (11.2, 11.2, 12.5, 12.5), (3.5, 12.5, 4.8, 11.2), (11.2, 4.8, 12.5, 3.5),
        ]
        for r in rays {
            path.move(to: p(r.0, r.1))
            path.line(to: p(r.2, r.3))
        }
        path.lineWidth = 1.5 * scale
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawAddTile() {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10.25, yRadius: 10.25)
        if isHovered {
            colors.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        }
        let ink = isHovered ? colors.inkPrimary : colors.inkSecondary
        ink.setStroke()
        shape.lineWidth = 1.5
        shape.setLineDash([4, 3], count: 2, phase: 0)
        shape.stroke()
        let plus = NSBezierPath()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        plus.move(to: NSPoint(x: c.x - 5.5, y: c.y))
        plus.line(to: NSPoint(x: c.x + 5.5, y: c.y))
        plus.move(to: NSPoint(x: c.x, y: c.y - 5.5))
        plus.line(to: NSPoint(x: c.x, y: c.y + 5.5))
        plus.lineWidth = 1.3
        plus.lineCapStyle = .round
        plus.stroke()
    }

    private func drawSliders() {
        if isHovered || isOn {
            colors.hover.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let ink = isHovered || isOn ? colors.inkPrimary : colors.inkSecondary
        ink.setStroke()
        let o = NSPoint(x: bounds.midX - 8, y: bounds.midY - 8)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x, y: o.y + y) }
        let path = NSBezierPath()
        for (a, b) in [((2.5, 4.5), (8.5, 4.5)), ((12.0, 4.5), (13.5, 4.5)), ((2.5, 11.5), (4.0, 11.5)), ((7.5, 11.5), (13.5, 11.5))] {
            path.move(to: p(a.0, a.1))
            path.line(to: p(b.0, b.1))
        }
        path.appendOval(in: NSRect(x: o.x + 10.2 - 1.7, y: o.y + 4.5 - 1.7, width: 3.4, height: 3.4))
        path.appendOval(in: NSRect(x: o.x + 5.8 - 1.7, y: o.y + 11.5 - 1.7, width: 3.4, height: 3.4))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.stroke()
        if showsBadge {
            let badge = NSRect(x: bounds.maxX - 3 - 7, y: 3, width: 7, height: 7)
            colors.surface.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
            FlyoutColors.warning.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }
}

/// The one flipped container for the rails, Settings and their flyouts.
class RailFlippedView: NSView {
    override var isFlipped: Bool { true }
}
