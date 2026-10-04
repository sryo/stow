import AppKit

/// "Where Stow lives": three picture cards, Floating, On top and Attached, under a
/// hairline bracket that pairs the first two as "Its own window". The chosen and the
/// hovered card loop their story; the others hold the frame that explains them; Reduce
/// Motion holds every card still. Below the cards a caption describes the chosen card,
/// or previews the hovered one. Choosing Attached opens the edge picker inline, with the
/// Accessibility warning or the "no browser in front" note when they apply.
///
/// From 290pt wide (the 340pt Settings page) the cards become rows that carry their
/// caption, with "Its own window" and "On your browser" as sub-labels.
///
/// The whole group is one key view: arrows move and choose like a radio group, Space and
/// Return choose the focused card. VoiceOver sees a radio group of three cards.
@MainActor
final class WindowPlacementPicker: NSView {
    enum Key { case left, right, up, down, select }

    static let rowsMinWidth: CGFloat = 290

    var placement = WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .left) {
        didSet { if placement != oldValue { stateChanged() } }
    }
    var hasAccessibility = true { didSet { if hasAccessibility != oldValue { stateChanged() } } }
    var browserInFront = true { didSet { if browserInFront != oldValue { stateChanged() } } }
    var surface: PlacementColors.Surface = .flyout {
        didSet {
            cards.forEach { $0.surface = surface }
            [ownLabel, browserLabel].forEach { $0.surface = surface }
            [ownSub, browserSub].forEach { $0.surface = surface }
            edgePicker.surface = surface
            warning.surface = surface
            note.surface = surface
            refreshLook()
        }
    }
    /// Reduce Motion: every card holds its key frame.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } {
        didSet { refreshMotion() }
    }

    var onChoose: ((AppWindowMode) -> Void)?
    var onChooseEdge: ((BrowserDock) -> Void)?
    var onAllow: (() -> Void)?
    /// The picker's height changed (a status row came or went, or a caption rewrapped).
    var onHeightChange: (() -> Void)?

    let edgePicker = BrowserDockPicker()
    private(set) var cards: [PlacementCard] = []
    private let ownLabel = PlacementBracket(title: WindowPlacementCopy.ownWindow)
    private let browserLabel = PlacementBracket(title: WindowPlacementCopy.onBrowser)
    private let ownSub = PlacementSubLabel(title: WindowPlacementCopy.ownWindow)
    private let browserSub = PlacementSubLabel(title: WindowPlacementCopy.onBrowser)
    private let descriptionText = PlacementText()
    private let previewTag = PlacementText()
    private let warning = PlacementWarningView()
    private let note = PlacementNoteView()

    private(set) var hoveredMode: AppWindowMode?
    private(set) var focusedMode: AppWindowMode?
    private var hasFocus = false
    private var focusVisible = false
    private lazy var elements: [PlacementCardElement] = AppWindowMode.allCases.map { PlacementCardElement(mode: $0, picker: self) }
    private var lastHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        // The cards' focus rings reach 3pt past the edges.
        clipsToBounds = false
        cards = AppWindowMode.allCases.map { PlacementCard(mode: $0) }
        for card in cards {
            card.onHover = { [weak self] mode, inside in self?.cardHover(mode, inside: inside) }
            card.onClick = { [weak self] mode in self?.choose(mode) }
            addSubview(card)
        }
        for view in [ownLabel, browserLabel, ownSub, browserSub, descriptionText, previewTag, edgePicker, warning, note] as [NSView] {
            addSubview(view)
        }
        edgePicker.onChange = { [weak self] edge in self?.onChooseEdge?(edge) }
        edgePicker.onHeightChange = { [weak self] in self?.relayout() }
        warning.onAllow = { [weak self] in self?.allow() }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(WindowPlacementCopy.groupTitle)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        stateChanged()
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 252, height: 160)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    @objc private func displayOptionsChanged() { refreshMotion() }

    // MARK: State

    var status: WindowPlacementStatus {
        WindowPlacementStatus(mode: placement.mode, hasAccessibility: hasAccessibility, browserInFront: browserInFront)
    }

    var isEdgePickerVisible: Bool { status.showsEdges }
    var isWarningVisible: Bool { status == .edgesNeedingAccessibility }
    var isNoteVisible: Bool { status == .edgesWithoutBrowser }
    var warningTitle: String { WindowPlacementCopy.warningTitle(placement.edge) }

    /// Rows instead of cards, from the page's width.
    var usesRows: Bool { bounds.width >= Self.rowsMinWidth }

    /// What the caption under the cards says now.
    var descriptionShown: WindowPlacementCopy.Description {
        WindowPlacementCopy.description(shown: hoveredMode ?? placement.mode, selected: placement.mode,
                                        hasAccessibility: hasAccessibility)
    }

    /// The bracket's two labels, in the picker's coordinates (cards only).
    var bracketFrames: (own: NSRect, browser: NSRect) { (ownLabel.frame, browserLabel.frame) }

    var showsFocusRing: Bool { hasFocus && focusVisible }

    private func stateChanged() {
        for card in cards {
            card.isSelected = card.mode == placement.mode
            card.showsBadge = card.mode == .attached && !hasAccessibility
            card.hasAccessibility = hasAccessibility
            card.illustration.edge = placement.edge
            card.illustration.isWaiting = card.mode == .attached && card.isSelected && !hasAccessibility
        }
        edgePicker.dock = placement.edge
        edgePicker.isWaiting = !hasAccessibility
        warning.title = warningTitle
        for element in elements {
            element.setAccessibilityValue(NSNumber(value: element.mode == placement.mode))
            element.setAccessibilityHelp(accessibilityHelp(for: element.mode))
        }
        refreshDescription()
        refreshMotion()
        relayout()
    }

    private func refreshDescription() {
        let shown = descriptionShown
        let ink = PlacementColors.ink(surface), ink2 = PlacementColors.inkSecondary(surface)
        let body = PlacementFonts.ui(11.5)
        var paragraphs = [PlacementText.Paragraph(runs: [
            PlacementRun(text: "\(WindowPlacementCopy.name(shown.mode)).", font: PlacementFonts.ui(11.5, 650), color: ink),
            PlacementRun(text: " \(WindowPlacementCopy.meaning(shown.mode))", font: body, color: ink),
        ], lineHeight: 15)]
        paragraphs.append(.init(runs: [
            PlacementRun(text: "e.g. ", font: body, color: ink2.withAlphaComponent(ink2.alphaComponent * 0.75)),
            PlacementRun(text: shown.example, font: body, color: ink2),
        ], lineHeight: 15, spacingBefore: 1))
        if let note = shown.accessibilityNote {
            paragraphs.append(.init(runs: [PlacementRun(text: note, font: PlacementFonts.ui(11.5, 600), color: PlacementColors.warning)],
                                    lineHeight: 15, spacingBefore: 1))
        }
        descriptionText.paragraphs = paragraphs
        previewTag.isHidden = !shown.isPreview || usesRows
        previewTag.paragraphs = [.init(runs: [PlacementRun(text: WindowPlacementCopy.previewTag, font: PlacementFonts.ui(10, 600),
                                                           color: ink2, kern: 0.2)], lineHeight: 15)]
        descriptionText.exclusion = shown.isPreview ? NSSize(width: previewTagWidth + 6, height: 15) : nil
    }

    private var previewTagWidth: CGFloat {
        ceil((WindowPlacementCopy.previewTag as NSString).size(withAttributes: [.font: PlacementFonts.ui(10, 600), .kern: 0.2]).width)
    }

    private func refreshLook() {
        refreshDescription()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLook()
    }

    /// Loops run on the chosen and the hovered card, never with Reduce Motion.
    func refreshMotion() {
        let still = reduceMotion()
        for card in cards {
            card.illustration.isAnimating = !still && (card.isSelected || card.mode == hoveredMode)
        }
    }

    // MARK: Choosing

    func choose(_ mode: AppWindowMode) {
        focusedMode = mode
        onChoose?(mode)
        needsLayout = true
    }

    func allow() { onAllow?() }

    /// The pointer over a card (nil when it leaves them). In the sheet the caption
    /// previews the hovered card; on the page each row carries its own.
    func hover(_ mode: AppWindowMode?) {
        guard mode != hoveredMode else { return }
        let width = max(0, bounds.width - 4)
        let before = descriptionText.height(forWidth: width)
        hoveredMode = mode
        for card in cards { card.isHovered = card.mode == mode }
        refreshDescription()
        // While the pointer is over the group the caption only grows: a shorter
        // preview would resize the popover under the pointer, which could move the
        // card out from under it and back, flickering.
        if pointerInside { reservedDescriptionHeight = max(reservedDescriptionHeight, before, descriptionText.height(forWidth: width)) }
        refreshMotion()
        relayout()
    }

    /// Whether the pointer is over the picker, and the caption height kept while it is.
    private(set) var pointerInside = false
    private(set) var reservedDescriptionHeight: CGFloat = 0

    /// The pointer came over the group or left it.
    func pointerMoved(inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if !inside {
            reservedDescriptionHeight = 0
            hover(nil)
            relayout()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(inside: true) }
    override func mouseExited(with event: NSEvent) { pointerMoved(inside: false) }

    private func cardHover(_ mode: AppWindowMode, inside: Bool) {
        if inside {
            pointerMoved(inside: true)
            hover(mode)
        } else if hoveredMode == mode {
            hover(nil)
        }
    }

    func handleKey(_ key: Key) {
        let all = AppWindowMode.allCases
        let current = focusedMode ?? placement.mode
        let index = all.firstIndex(of: current) ?? 0
        switch key {
        case .right, .down: choose(all[(index + 1) % all.count])
        case .left, .up: choose(all[(index + all.count - 1) % all.count])
        case .select: choose(current)
        }
        refreshFocus()
    }

    // MARK: Layout

    private func relayout() {
        needsLayout = true
        let height = height(forWidth: bounds.width)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            onHeightChange?()
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat { layoutPieces(width: width, apply: false) }

    override func layout() {
        super.layout()
        lastHeight = layoutPieces(width: bounds.width, apply: true)
    }

    @discardableResult
    private func layoutPieces(width: CGFloat, apply: Bool) -> CGFloat {
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        let rows = width >= Self.rowsMinWidth
        var y: CGFloat = 0
        if apply {
            for view in [ownLabel, browserLabel] { view.isHidden = rows }
            for view in [ownSub, browserSub] { view.isHidden = !rows }
            descriptionText.isHidden = rows
            if rows { previewTag.isHidden = true }
            cards.forEach { $0.style = rows ? .row : .card }
        }
        if rows {
            // .rsub: 6pt above, 12pt, 3pt below; .rlist gap 2.
            for (index, card) in cards.enumerated() {
                if index == 0 || index == 2 {
                    y += index == 0 ? 6 : 6 + 2
                    place(index == 0 ? ownSub : browserSub, NSRect(x: 2, y: y, width: width - 4, height: 12))
                    y += 12 + 3 + 2
                } else {
                    y += 2
                }
                let h = card.rowHeight(forWidth: width)
                place(card, NSRect(x: 0, y: y, width: width, height: h))
                y += h
            }
        } else {
            // .brk: 2fr 1fr with a 6pt gap, 16pt tall, then the cards 6pt below less 1.
            let bracketWidth = width - 6
            let own = (bracketWidth * 2 / 3).rounded()
            place(ownLabel, NSRect(x: 0, y: 0, width: own, height: 16))
            place(browserLabel, NSRect(x: own + 6, y: 0, width: width - own - 6, height: 16))
            y = 16 - 1 + 6
            let cardWidth = ((width - 12) / 3).rounded(.down)
            for (index, card) in cards.enumerated() {
                place(card, NSRect(x: CGFloat(index) * (cardWidth + 6), y: y, width: cardWidth, height: PlacementCard.cardHeight))
            }
            y += PlacementCard.cardHeight
            // .desc: 7pt below, 2pt in, at least 47pt.
            y += 7
            let textWidth = width - 4
            let h = max(47, descriptionText.height(forWidth: textWidth), reservedDescriptionHeight)
            place(descriptionText, NSRect(x: 2, y: y, width: textWidth, height: h))
            let tag = previewTagWidth
            place(previewTag, NSRect(x: 2 + textWidth - tag, y: y, width: tag, height: 15))
            y += h
        }
        let state = status
        if apply {
            if edgePicker.isHidden == state.showsEdges || warning.isHidden == (state == .edgesNeedingAccessibility) {
                // Controls came or went: the window's Tab order has to include them.
                DispatchQueue.main.async { [weak self] in self?.window?.recalculateKeyViewLoop() }
            }
            edgePicker.isHidden = !state.showsEdges
            warning.isHidden = state != .edgesNeedingAccessibility
            note.isHidden = state != .edgesWithoutBrowser
            edgePicker.compact = !rows
        }
        if state.showsEdges {
            y += 6
            let h = edgePicker.height(forWidth: width, compact: !rows)
            place(edgePicker, NSRect(x: 0, y: y, width: width, height: h))
            y += h
        }
        if state == .edgesNeedingAccessibility {
            y += 6
            let h = warning.height(forWidth: width)
            place(warning, NSRect(x: 0, y: y, width: width, height: h))
            y += h
        }
        if state == .edgesWithoutBrowser {
            y += 6
            let h = note.height(forWidth: width)
            place(note, NSRect(x: 0, y: y, width: width, height: h))
            y += h
        }
        return y
    }

    /// The focused card's ring: box-shadow 0 0 0 3px var(--focus), outside the card.
    override func draw(_ dirtyRect: NSRect) {
        guard let card = cards.first(where: \.showsFocusRing), let context = NSGraphicsContext.current?.cgContext else { return }
        let ring = CGMutablePath()
        ring.addRoundedRect(in: card.frame.insetBy(dx: -3, dy: -3), cornerWidth: 13, cornerHeight: 13)
        ring.addRoundedRect(in: card.frame, cornerWidth: 10, cornerHeight: 10)
        context.addPath(ring)
        context.setFillColor(placementCG(PlacementColors.focus))
        context.fillPath(using: .evenOdd)
    }

    // MARK: Keyboard

    /// Clicks, and windows opening after one, don't move focus (FocusRing); Tab does.
    override var acceptsFirstResponder: Bool { FocusRing.acceptsFocusNow }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        focusVisible = FocusRing.focusCameFromKeyboard()
        focusedMode = placement.mode
        refreshFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        focusVisible = false
        refreshFocus()
        return true
    }

    private func refreshFocus() {
        for card in cards { card.showsFocusRing = showsFocusRing && card.mode == (focusedMode ?? placement.mode) }
        if hasFocus, let mode = focusedMode, let element = elements.first(where: { $0.mode == mode }) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        case 49, 36, 76: key = .select
        default: key = nil
        }
        // Keys a focused child (Allow…) passes up aren't for the group.
        guard let key, window?.firstResponder.map({ $0 === self }) ?? true else { return super.keyDown(with: event) }
        focusVisible = true
        handleKey(key)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = elements
        for view in [edgePicker, warning, note] as [NSView] where !view.isHidden { children.append(view) }
        return children
    }

    fileprivate func card(for mode: AppWindowMode) -> PlacementCard? { cards.first { $0.mode == mode } }

    fileprivate func accessibilityHelp(for mode: AppWindowMode) -> String {
        let meaning = WindowPlacementCopy.meaning(mode)
        return mode == .attached && !hasAccessibility ? "\(meaning) \(WindowPlacementCopy.needsAccessibility)" : meaning
    }
}

/// One card, as VoiceOver sees it: a radio button named for its mode.
@MainActor
private final class PlacementCardElement: NSAccessibilityElement {
    let mode: AppWindowMode
    private weak var picker: WindowPlacementPicker?

    init(mode: AppWindowMode, picker: WindowPlacementPicker) {
        self.mode = mode
        self.picker = picker
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(WindowPlacementCopy.name(mode))
        setAccessibilityParent(picker)
        setAccessibilityValue(NSNumber(value: false))
    }

    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let picker, let card = picker.card(for: mode) else { return .zero }
        let rect = card.frame
        return NSRect(x: rect.minX, y: picker.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    override func accessibilityPerformPress() -> Bool {
        picker?.choose(mode)
        return true
    }
}

// MARK: - Card

/// A card (picture over its name) or, on the page, a row (picture, name, meaning and
/// example, and a radio dot).
@MainActor
final class PlacementCard: NSView {
    enum Style { case card, row }

    static let cardHeight: CGFloat = 75

    let mode: AppWindowMode
    let illustration = PlacementIllustration()
    var style: Style = .card { didSet { if style != oldValue { refreshText(); needsLayout = true; needsDisplay = true } } }
    var surface: PlacementColors.Surface = .flyout { didSet { refreshText(); needsDisplay = true } }
    var isSelected = false { didSet { if isSelected != oldValue { refreshText(); needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { refreshText(); needsDisplay = true } } }
    /// The picker draws the ring around the card (box-shadow: 0 0 0 3px var(--focus)).
    var showsFocusRing = false { didSet { if showsFocusRing != oldValue { superview?.needsDisplay = true } } }
    var showsBadge = false { didSet { badge.isHidden = !showsBadge; refreshText() } }
    var hasAccessibility = true { didSet { if hasAccessibility != oldValue { refreshText() } } }
    var onHover: ((AppWindowMode, Bool) -> Void)?
    var onClick: ((AppWindowMode) -> Void)?

    private let name = PlacementText()
    private let badge = PlacementBadge()

    init(mode: AppWindowMode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = 10
        illustration.mode = mode
        addSubview(illustration)
        addSubview(name)
        addSubview(badge)
        badge.isHidden = true
        setAccessibilityElement(false)
        refreshText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private var ink: NSColor { PlacementColors.ink(surface) }
    private var ink2: NSColor { PlacementColors.inkSecondary(surface) }

    private func refreshText() {
        badge.surface = surface
        illustration.hairlineColor = PlacementColors.line(surface)
        switch style {
        case .card:
            name.alignment = .center
            let active = isSelected || isHovered
            name.paragraphs = [.init(runs: [PlacementRun(text: WindowPlacementCopy.name(mode),
                                                         font: PlacementFonts.ui(11.5, isSelected ? 650 : 550),
                                                         color: active ? ink : ink2)], lineHeight: 14)]
        case .row:
            name.alignment = .left
            let body = PlacementFonts.ui(11.5)
            var paragraphs: [PlacementText.Paragraph] = [
                .init(runs: [PlacementRun(text: WindowPlacementCopy.name(mode), font: PlacementFonts.ui(12.5, 650), color: ink)], lineHeight: 16),
                .init(runs: [PlacementRun(text: WindowPlacementCopy.meaning(mode), font: body, color: ink)], lineHeight: 15),
                .init(runs: [PlacementRun(text: WindowPlacementCopy.example(mode), font: body, color: ink2)], lineHeight: 15, spacingBefore: 2),
            ]
            if mode == .attached, !hasAccessibility, !isSelected {
                paragraphs.append(.init(runs: [PlacementRun(text: WindowPlacementCopy.needsAccessibility, font: PlacementFonts.ui(11.5, 600),
                                                            color: PlacementColors.warning)], lineHeight: 15, spacingBefore: 2))
            }
            name.paragraphs = paragraphs
        }
        needsLayout = true
    }

    private static func textWidth(forWidth width: CGFloat) -> CGFloat {
        // .rcard: 5 + 90 + 10 | text | 10 + 16 + 2 + 5
        width - 5 - 90 - 10 - 10 - 16 - 2 - 5
    }

    func rowHeight(forWidth width: CGFloat) -> CGFloat {
        5 + max(60, name.height(forWidth: Self.textWidth(forWidth: width))) + 5
    }

    var illustrationFrame: NSRect {
        switch style {
        case .card: return NSRect(x: 4, y: 4, width: bounds.width - 8, height: ((bounds.width - 8) * 2 / 3).rounded())
        case .row: return NSRect(x: 5, y: (bounds.height - 60) / 2, width: 90, height: 60)
        }
    }

    private var radioFrame: NSRect {
        NSRect(x: bounds.width - 5 - 2 - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func layout() {
        super.layout()
        let art = illustrationFrame
        illustration.frame = art
        switch style {
        case .card:
            name.frame = NSRect(x: 0, y: art.maxY + 4, width: bounds.width, height: 14)
            badge.frame = NSRect(x: bounds.width - 2 - 15 - 2, y: 2 - 2, width: 19, height: 19)
        case .row:
            let width = Self.textWidth(forWidth: bounds.width)
            name.frame = NSRect(x: art.maxX + 10, y: 5, width: width, height: name.height(forWidth: width))
            badge.frame = NSRect(x: 84 - 2, y: 1 - 2, width: 19, height: 19)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isHovered {
            context.setFillColor(placementCG(PlacementColors.hover(surface)))
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
        }
        if isSelected {
            // box-shadow: 0 0 0 2px var(--c-bg), 0 0 0 3.5px var(--c-ink)
            let art = illustrationFrame
            context.setFillColor(placementCG(ink))
            context.addPath(CGPath(roundedRect: art.insetBy(dx: -3.5, dy: -3.5), cornerWidth: 10.5, cornerHeight: 10.5, transform: nil))
            context.fillPath()
            context.setFillColor(placementCG(PlacementColors.background(surface)))
            context.addPath(CGPath(roundedRect: art.insetBy(dx: -2, dy: -2), cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.fillPath()
        }
        if style == .row {
            let dot = radioFrame
            context.setFillColor(placementCG(isSelected ? ink : ink2))
            let thickness: CGFloat = isSelected ? 5 : 1.5
            context.addEllipse(in: dot)
            context.addEllipse(in: dot.insetBy(dx: thickness, dy: thickness))
            context.fillPath(using: .evenOdd)
        }
    }


    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshText()
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(mode, true) }
    override func mouseExited(with event: NSEvent) { onHover?(mode, false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(mode) }
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Pieces

/// The "!" badge on the Attached card while Accessibility is missing: a 15pt amber dot
/// in a 2pt ring of the background.
@MainActor
final class PlacementBadge: NSView {
    var surface: PlacementColors.Surface = .flyout { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(placementCG(PlacementColors.background(surface)))
        context.fillEllipse(in: bounds)
        let dot = bounds.insetBy(dx: 2, dy: 2)
        context.setFillColor(placementCG(PlacementColors.warning))
        context.fillEllipse(in: dot)
        PlacementBadge.drawMark(in: dot, view: self)
    }

    /// The "!" centered in a 15pt dot: 10pt, weight 800.
    static func drawMark(in dot: NSRect, view: NSView) {
        let font = PlacementFonts.ui(10, 800)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PlacementColors.onWarning]
        let mark = NSAttributedString(string: "!", attributes: attributes)
        let size = mark.size()
        // CSS line-height 15: the glyphs sit centered in the dot's height.
        let natural = font.ascender - font.descender
        let baselineTop = dot.minY + (dot.height - natural) / 2
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            mark.draw(at: NSPoint(x: dot.midX - size.width / 2, y: baselineTop))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One half of the bracket over the cards: a small centered label over a hairline that
/// turns down 4pt at both ends.
@MainActor
final class PlacementBracket: NSView {
    let title: String
    var surface: PlacementColors.Surface = .flyout { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let line = placementCG(PlacementColors.line(surface))
        context.setFillColor(line)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
        context.fill(CGRect(x: 0, y: bounds.height - 4, width: 1, height: 4))
        context.fill(CGRect(x: bounds.width - 1, y: bounds.height - 4, width: 1, height: 4))
        let font = PlacementFonts.ui(9.5, 600)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: PlacementColors.inkSecondary(surface)])
        let size = text.size()
        let natural = font.ascender - font.descender
        effectiveAppearance.performAsCurrentDrawingAppearance {
            text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2), y: (11 - natural) / 2))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The page's sub-label: "Its own window ————", 10pt semibold with a hairline after it.
@MainActor
final class PlacementSubLabel: NSView {
    let title: String
    var surface: PlacementColors.Surface = .page { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let font = PlacementFonts.ui(10, 600)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: PlacementColors.inkSecondary(surface)])
        let size = text.size()
        let natural = font.ascender - font.descender
        effectiveAppearance.performAsCurrentDrawingAppearance {
            text.draw(at: NSPoint(x: 0, y: (12 - natural) / 2))
        }
        context.setFillColor(placementCG(PlacementColors.line(surface)))
        let x = ceil(size.width) + 6
        context.fill(CGRect(x: x, y: 6, width: max(0, bounds.width - x), height: 1))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// "! Attached needs Accessibility. Stow floats until you allow it.  [Allow…]"
@MainActor
final class PlacementWarningView: NSView {
    var title = "" { didSet { refresh() } }
    var surface: PlacementColors.Surface = .flyout { didSet { if surface != oldValue { refresh(); allowButton.surface = surface } } }
    var onAllow: (() -> Void)?
    let allowButton = PlacementButton(title: WindowPlacementCopy.allow)
    private let text = PlacementText()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        addSubview(text)
        addSubview(allowButton)
        allowButton.target = self
        allowButton.action = #selector(allowTapped)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    @objc private func allowTapped() { onAllow?() }

    private func refresh() {
        text.paragraphs = [
            .init(runs: [PlacementRun(text: title, font: PlacementFonts.ui(11.5, 650), color: PlacementColors.ink(surface))], lineHeight: 15),
            .init(runs: [PlacementRun(text: WindowPlacementCopy.warningDetail, font: PlacementFonts.ui(11),
                                      color: PlacementColors.inkSecondary(surface))], lineHeight: 15),
        ]
        setAccessibilityLabel("\(title) \(WindowPlacementCopy.warningDetail)")
        needsDisplay = true
        needsLayout = true
    }

    private func textWidth(_ width: CGFloat) -> CGFloat { width - 8 - 15 - 7 - 7 - allowButton.fittingWidth - 8 }

    func height(forWidth width: CGFloat) -> CGFloat {
        7 + max(22, text.height(forWidth: textWidth(width))) + 7
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = placementCG(PlacementColors.warningFill)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dot = NSRect(x: 8, y: 7, width: 15, height: 15)
        context.setFillColor(placementCG(PlacementColors.warning))
        context.fillEllipse(in: dot)
        PlacementBadge.drawMark(in: dot, view: self)
    }

    override func layout() {
        super.layout()
        let width = textWidth(bounds.width)
        text.frame = NSRect(x: 8 + 15 + 7, y: 7, width: width, height: text.height(forWidth: width))
        let button = allowButton.fittingWidth
        allowButton.frame = NSRect(x: bounds.width - 8 - button, y: 7, width: button, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

/// "○ No browser window in front. Stow floats until one is." A quiet note, not a warning.
@MainActor
final class PlacementNoteView: NSView {
    var surface: PlacementColors.Surface = .flyout { didSet { if surface != oldValue { refresh() } } }
    private let text = PlacementText()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(WindowPlacementCopy.noBrowser)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func refresh() {
        text.paragraphs = [.init(runs: [PlacementRun(text: WindowPlacementCopy.noBrowser, font: PlacementFonts.ui(11),
                                                     color: PlacementColors.inkSecondary(surface))], lineHeight: 14)]
        needsDisplay = true
    }

    private func textWidth(_ width: CGFloat) -> CGFloat { width - 8 - 7 - 7 - 8 }

    func height(forWidth width: CGFloat) -> CGFloat { 6 + text.height(forWidth: textWidth(width)) + 6 }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = placementCG(PlacementColors.field(surface))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dot = NSRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)
        context.setStrokeColor(placementCG(PlacementColors.inkSecondary(surface)))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
    }

    override func layout() {
        super.layout()
        let width = textWidth(bounds.width)
        let h = text.height(forWidth: width)
        text.frame = NSRect(x: 8 + 7 + 7, y: (bounds.height - h) / 2, width: width, height: h)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

/// Allow…: 22pt, 9pt sides, radius 6, raised with a hairline and a soft shadow.
@MainActor
final class PlacementButton: FlyoutControl {
    let title: String
    var surface: PlacementColors.Surface = .flyout { didSet { needsDisplay = true } }
    private static var font: NSFont { PlacementFonts.ui(11.5, 550) }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        layer?.cornerRadius = 6
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: Self.font]).width * 100) / 100 + 18
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let layer else { return }
        let fill = PlacementColors.button(surface)
        layer.backgroundColor = placementCG(isPressed ? fill.blended(withFraction: 0.06, of: .black) ?? fill
                                            : isHovered ? fill.blended(withFraction: 0.03, of: .black) ?? fill : fill)
        layer.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 0.5
        layer.borderColor = placementCG(isFocused ? SettingsColors.accent : PlacementColors.line(surface))
        layer.shadowColor = .black
        layer.shadowOpacity = 0.12
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowRadius = 1
        let font = Self.font
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: PlacementColors.ink(surface)])
        let natural = font.ascender - font.descender
        text.draw(at: NSPoint(x: 9, y: (bounds.height - natural) / 2))
    }
}
