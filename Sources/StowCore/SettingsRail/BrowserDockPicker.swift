import AppKit

/// The edge picker that opens under Attached: a small browser window with four clickable
/// edges, and beside it what the edge does. Left and right attach the sidebar there; top
/// and bottom put the Tabline on that edge and ask nothing more. The sides are drawn as
/// panels and the top and bottom as tab strips, so it's clear before you click.
///
/// Hovering an edge previews its caption. Arrow keys choose the edge they point at (↑
/// top, ↓ bottom, ← left, → right); Space or Return chooses the focused one. Its API is
/// `dock` in and `onChange` out.
@MainActor
final class BrowserDockPicker: NSView {
    enum Key { case up, down, left, right, select }

    /// VoiceOver and drawing order: top, left, right, bottom, as in the design.
    static let order: [BrowserDock] = [.top, .left, .right, .bottom]

    var dock: BrowserDock = .left { didSet { if dock != oldValue { stateChanged() } } }
    /// Accessibility is missing: the chosen edge is drawn dashed amber.
    var isWaiting = false { didSet { if isWaiting != oldValue { needsDisplay = true } } }
    var surface: PlacementColors.Surface = .flyout { didSet { refreshCaption(); needsDisplay = true } }
    /// The sheet's smaller drawing (96×66) or the page's (104×70).
    var compact = true { didSet { if compact != oldValue { needsLayout = true; needsDisplay = true } } }
    var onChange: ((BrowserDock) -> Void)?
    var onHeightChange: (() -> Void)?

    var hoveredEdge: BrowserDock? { didSet { if hoveredEdge != oldValue { refreshCaption(); needsDisplay = true } } }
    private(set) var focusedEdge: BrowserDock?
    private var hasFocus = false
    private var focusVisible = false
    private let captionText = PlacementText()
    private lazy var edgeElements: [EdgeElement] = Self.order.map { EdgeElement(edge: $0, picker: self) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        addSubview(captionText)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(WindowPlacementCopy.edgeGroup)
        stateChanged()
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 252, height: 91)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var showsFocusRing: Bool { hasFocus && focusVisible }

    // MARK: Caption

    struct Caption: Equatable { var title: String; var detail: String; var hint: String }

    /// The hovered edge's words, else the chosen edge's.
    var caption: Caption {
        let edge = hoveredEdge ?? dock
        return Caption(title: WindowPlacementCopy.edgeTitle(edge), detail: WindowPlacementCopy.edgeDetail(edge),
                       hint: WindowPlacementCopy.edgeHint(edge))
    }

    private func refreshCaption() {
        let words = caption
        let ink2 = PlacementColors.inkSecondary(surface)
        captionText.paragraphs = [
            .init(runs: [PlacementRun(text: words.title, font: PlacementFonts.ui(11.5, 650), color: PlacementColors.ink(surface))], lineHeight: 15),
            .init(runs: [PlacementRun(text: words.detail, font: PlacementFonts.ui(11.5), color: ink2)], lineHeight: 15),
            .init(runs: [PlacementRun(text: words.hint, font: PlacementFonts.ui(10.5), color: ink2)], lineHeight: 13, spacingBefore: 4),
        ]
        needsLayout = true
        onHeightChange?()
    }

    private func stateChanged() {
        for element in edgeElements { element.setAccessibilityValue(NSNumber(value: element.edge == dock)) }
        refreshCaption()
        needsDisplay = true
    }

    // MARK: Geometry

    /// The drawing's size: .eb.
    static func drawingSize(compact: Bool) -> NSSize {
        compact ? NSSize(width: 96, height: 66) : NSSize(width: 104, height: 70)
    }

    /// The browser window in the drawing: .ebw.
    static func windowRect(compact: Bool) -> NSRect {
        compact ? NSRect(x: 20, y: 15, width: 56, height: 36) : NSRect(x: 22, y: 16, width: 60, height: 38)
    }

    /// Each edge's clickable zone in the drawing: .ez.
    static func zones(compact: Bool) -> [BrowserDock: NSRect] {
        let size = drawingSize(compact: compact)
        let window = windowRect(compact: compact)
        let side: CGFloat = 13, inset: CGFloat = compact ? 4 : 5, strip: CGFloat = compact ? 9 : 10
        return [
            .left: NSRect(x: inset, y: window.minY, width: side, height: window.height),
            .right: NSRect(x: size.width - inset - side, y: window.minY, width: side, height: window.height),
            .top: NSRect(x: window.minX, y: 3, width: window.width, height: strip),
            .bottom: NSRect(x: window.minX, y: size.height - 3 - strip, width: window.width, height: strip),
        ]
    }

    /// The edge under `point`, in the drawing's coordinates: a zone, with 3pt of slack
    /// around the thin strips; the nearest zone wins where the slack overlaps.
    static func edge(at point: NSPoint, compact: Bool) -> BrowserDock? {
        let hits = zones(compact: compact).filter { $0.value.insetBy(dx: -3, dy: -3).contains(point) }
        func distance(_ rect: NSRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return hits.min { distance($0.value) < distance($1.value) }?.key
    }

    /// Where the drawing sits in the picker: 8pt in, centered on the caption.
    private var drawingOrigin: NSPoint {
        let size = Self.drawingSize(compact: compact)
        return NSPoint(x: 8, y: (bounds.height - size.height) / 2)
    }

    private func captionWidth(_ width: CGFloat, compact: Bool) -> CGFloat {
        width - 8 - Self.drawingSize(compact: compact).width - 10 - 8
    }

    func height(forWidth width: CGFloat, compact: Bool) -> CGFloat {
        8 + max(Self.drawingSize(compact: compact).height, captionText.height(forWidth: captionWidth(width, compact: compact))) + 8
    }

    override func layout() {
        super.layout()
        let width = captionWidth(bounds.width, compact: compact)
        let h = captionText.height(forWidth: width)
        captionText.frame = NSRect(x: 8 + Self.drawingSize(compact: compact).width + 10, y: ((bounds.height - h) / 2).rounded(.down),
                                   width: width, height: h)
    }

    private func zoneInView(_ edge: BrowserDock) -> NSRect {
        let origin = drawingOrigin
        return (Self.zones(compact: compact)[edge] ?? .zero).offsetBy(dx: origin.x, dy: origin.y)
    }

    private func edge(atViewPoint point: NSPoint) -> BrowserDock? {
        let origin = drawingOrigin
        return Self.edge(at: NSPoint(x: point.x - origin.x, y: point.y - origin.y), compact: compact)
    }

    // MARK: Choosing

    /// A click, Space or VoiceOver press on `edge`. Choosing the chosen edge again keeps
    /// it (and asks for Accessibility again if it's still missing).
    func choose(_ edge: BrowserDock) {
        focusedEdge = edge
        onChange?(edge)
        needsDisplay = true
    }

    func handleKey(_ key: Key) {
        switch key {
        case .up: choose(.top)
        case .down: choose(.bottom)
        case .left: choose(.left)
        case .right: choose(.right)
        case .select: choose(focusedEdge ?? dock)
        }
        if let focusedEdge, let element = edgeElements.first(where: { $0.edge == focusedEdge }) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = placementCG(PlacementColors.field(surface))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = drawingOrigin
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        drawWindow(context)
        for edge in Self.order { drawZone(edge, context) }
        context.restoreGState()
    }

    private func drawWindow(_ context: CGContext) {
        let w = Self.windowRect(compact: compact)
        let path = CGPath(roundedRect: w, cornerWidth: 4, cornerHeight: 4, transform: nil)
        // box-shadow: 0 0 0 .5px var(--w-edge), 0 1px 3px rgba(0,0,0,.12)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor(white: 0, alpha: 0.12).cgColor)
        context.setFillColor(placementCG(PlacementColors.browser))
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(placementCG(PlacementColors.edge))
        context.setLineWidth(0.5)
        context.addPath(CGPath(roundedRect: w.insetBy(dx: -0.25, dy: -0.25), cornerWidth: 4.25, cornerHeight: 4.25, transform: nil))
        context.strokePath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(placementCG(PlacementColors.bar))
        context.fill(CGRect(x: w.minX, y: w.minY, width: w.width, height: 7))
        context.setFillColor(placementCG(PlacementColors.edge))
        for x: CGFloat in [3, 7, 11] {
            context.fillEllipse(in: CGRect(x: w.minX + x, y: w.minY + 2.5, width: 2.5, height: 2.5))
        }
        context.setFillColor(placementCG(PlacementColors.textLine))
        for (top, right) in [(12, 10), (18, 20), (24, 10)] as [(CGFloat, CGFloat)] {
            let line = CGRect(x: w.minX + 6, y: w.minY + top, width: w.width - 6 - right, height: 2.5)
            context.addPath(CGPath(roundedRect: line, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }

    private func drawZone(_ edge: BrowserDock, _ context: CGContext) {
        guard let zone = Self.zones(compact: compact)[edge] else { return }
        let chosen = edge == dock
        let hovered = edge == hoveredEdge
        let focused = showsFocusRing && edge == (focusedEdge ?? dock)
        let radius: CGFloat = 3.5
        if focused {
            // box-shadow: 0 0 0 3px var(--focus), outside the zone.
            let ring = CGMutablePath()
            ring.addRoundedRect(in: zone.insetBy(dx: -3, dy: -3), cornerWidth: radius + 3, cornerHeight: radius + 3)
            ring.addRoundedRect(in: zone, cornerWidth: radius, cornerHeight: radius)
            context.addPath(ring)
            context.setFillColor(placementCG(PlacementColors.focus))
            context.fillPath(using: .evenOdd)
        }
        if chosen {
            if isWaiting {
                // .ez.on.wn: a 1.5px dashed amber border, the stripes at a third.
                context.setStrokeColor(placementCG(PlacementColors.warning))
                context.setLineWidth(1.5)
                context.setLineDash(phase: 0, lengths: [4.5, 3])
                context.addPath(CGPath(roundedRect: zone.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius - 0.75, cornerHeight: radius - 0.75,
                                       transform: nil))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
                drawStripes(edge, in: zone.insetBy(dx: 1.5, dy: 1.5), opacity: 0.35, context)
            } else {
                let path = CGPath(roundedRect: zone, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setFillColor(placementCG(PlacementColors.stow))
                context.addPath(path)
                context.fillPath()
                // inset 0 0 0 1px var(--w-edge)
                context.setStrokeColor(placementCG(PlacementColors.edge))
                context.setLineWidth(1)
                context.addPath(CGPath(roundedRect: zone.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5,
                                       transform: nil))
                context.strokePath()
                drawStripes(edge, in: zone, opacity: 1, context)
            }
            return
        }
        let inner = CGPath(roundedRect: zone.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil)
        if hovered {
            context.setFillColor(placementCG(PlacementColors.hover(surface)))
            context.addPath(CGPath(roundedRect: zone, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.setStrokeColor(placementCG(PlacementColors.ink(surface)))
            context.setLineWidth(1)
            context.addPath(inner)
            context.strokePath()
        } else {
            // A 1px dashed border in ink2 at 75%, like the CSS default.
            let ink2 = PlacementColors.inkSecondary(surface)
            context.setStrokeColor(placementCG(ink2.withAlphaComponent(ink2.alphaComponent * (focused ? 1 : 0.75))))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.addPath(inner)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    /// The chosen edge's content: rows of links in a side panel (1.5pt lines every 5pt,
    /// 3pt in), tabs in a strip (4pt bars every 7pt, 2.5pt by 4pt in).
    private func drawStripes(_ edge: BrowserDock, in zone: NSRect, opacity: CGFloat, _ context: CGContext) {
        let ink = PlacementColors.stowInk
        context.setFillColor(placementCG(ink.withAlphaComponent(ink.alphaComponent * opacity)))
        if edge.isSidebar {
            let area = zone.insetBy(dx: 3, dy: 3)
            var y = area.minY
            while y < area.maxY {
                context.fill(CGRect(x: area.minX, y: y, width: area.width, height: min(1.5, area.maxY - y)))
                y += 5
            }
        } else {
            let area = zone.insetBy(dx: 4, dy: 2.5)
            var x = area.minX
            while x < area.maxX {
                context.fill(CGRect(x: x, y: area.minY, width: min(4, area.maxX - x), height: area.height))
                x += 7
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshCaption()
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredEdge = edge(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) { hoveredEdge = nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let edge = edge(atViewPoint: convert(event.locationInWindow, from: nil)) else { return }
        choose(edge)
    }

    override func resetCursorRects() {
        for edge in Self.order { addCursorRect(zoneInView(edge).insetBy(dx: -3, dy: -3), cursor: .pointingHand) }
    }

    // MARK: Keyboard

    /// Clicks, and windows opening after one, don't move focus (FocusRing); Tab does.
    override var acceptsFirstResponder: Bool { FocusRing.acceptsFocusNow }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        focusVisible = FocusRing.focusCameFromKeyboard()
        focusedEdge = dock
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        focusVisible = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch event.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 49, 36, 76: key = .select
        default: key = nil
        }
        // Keys a focused child (Allow…) passes up aren't for the group.
        guard let key, window?.firstResponder.map({ $0 === self }) ?? true else { return super.keyDown(with: event) }
        focusVisible = true
        handleKey(key)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { edgeElements }

    fileprivate func accessibilityFrame(for edge: BrowserDock) -> NSRect { zoneInView(edge) }
}

/// One edge, as VoiceOver sees it: a radio button whose value says whether it's chosen.
@MainActor
private final class EdgeElement: NSAccessibilityElement {
    let edge: BrowserDock
    private weak var picker: BrowserDockPicker?

    init(edge: BrowserDock, picker: BrowserDockPicker) {
        self.edge = edge
        self.picker = picker
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(WindowPlacementCopy.edgeTitle(edge))
        setAccessibilityHelp(WindowPlacementCopy.edgeDetail(edge))
        setAccessibilityParent(picker)
        setAccessibilityValue(NSNumber(value: false))
    }

    override func accessibilityFrameInParentSpace() -> NSRect {
        guard let picker else { return .zero }
        let rect = picker.accessibilityFrame(for: edge)
        // Parent space is unflipped.
        return NSRect(x: rect.minX, y: picker.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    override func accessibilityPerformPress() -> Bool {
        picker?.choose(edge)
        return true
    }
}
