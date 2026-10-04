import AppKit

/// "With your browser": a small browser window with four clickable edges. Left and right
/// attach the sidebar there; top and bottom dock the Tabline on that edge. Clicking the
/// selected edge again detaches. Arrow keys move between edges, Space or Return chooses,
/// Delete detaches.
///
/// Its whole API is `dock` in and `onChange` out, so the drawing can be replaced without
/// touching AppPreferences.
@MainActor
final class BrowserDockPicker: NSView {
    enum Key { case up, down, left, right, select, clear }

    static let edges: [BrowserDock] = [.left, .right, .top, .bottom]
    static let preferredHeight: CGFloat = 112
    /// Room around the window drawing for the docked sidebar and Tabline.
    private static let margin: CGFloat = 16
    private static let sideMargin: CGFloat = 32

    var dock: BrowserDock = .none { didSet { if dock != oldValue { stateChanged() } } }
    /// The workspace accent the selected edge is drawn in.
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onChange: ((BrowserDock) -> Void)?

    private(set) var focusedEdge: BrowserDock?
    private var hoveredEdge: BrowserDock? { didSet { if hoveredEdge != oldValue { needsDisplay = true } } }
    private var isFocused = false
    private var tracking: NSTrackingArea?
    private lazy var edgeElements: [EdgeElement] = Self.edges.map { EdgeElement(edge: $0, picker: self) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("With your browser")
        stateChanged()
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.preferredHeight)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Choosing

    /// What a click or Space on `edge` does: choose it, or detach if it's already chosen.
    func choose(_ edge: BrowserDock) {
        focusedEdge = edge
        onChange?(edge == dock ? .none : edge)
    }

    func handleKey(_ key: Key) {
        switch key {
        case .up: focus(.top)
        case .down: focus(.bottom)
        case .left: focus(.left)
        case .right: focus(.right)
        case .select: if let focusedEdge { choose(focusedEdge) }
        case .clear: if dock != .none { onChange?(.none) }
        }
    }

    private func focus(_ edge: BrowserDock) {
        focusedEdge = edge
        needsDisplay = true
        if let element = edgeElements.first(where: { $0.edge == edge }) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    private func stateChanged() {
        for element in edgeElements { element.setAccessibilityValue(NSNumber(value: element.edge == dock)) }
        needsDisplay = true
    }

    // MARK: Geometry

    /// The browser window drawing inside `bounds`.
    var windowRect: NSRect {
        let m = Self.margin
        let width = min(bounds.width - Self.sideMargin * 2, 200)
        return NSRect(x: (bounds.width - width) / 2, y: m, width: width, height: bounds.height - m * 2)
    }

    /// The edge under `point` (flipped coordinates), or nil for the middle of the window
    /// and anywhere outside it and its margin.
    static func edge(at point: NSPoint, window: NSRect) -> BrowserDock? {
        guard window.insetBy(dx: -sideMargin, dy: -margin).contains(point) else { return nil }
        let thickness = 0.28 * min(window.width, window.height)
        let distances: [(BrowserDock, CGFloat)] = [
            (.left, point.x - window.minX), (.right, window.maxX - point.x),
            (.top, point.y - window.minY), (.bottom, window.maxY - point.y),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= thickness else { return nil }
        return nearest.0
    }

    /// Where the docked sidebar or Tabline is drawn for `edge`.
    private func dockRect(_ edge: BrowserDock) -> NSRect {
        let w = windowRect
        let side: CGFloat = 26, strip: CGFloat = 9, gap: CGFloat = 3
        switch edge {
        case .left: return NSRect(x: w.minX - side - gap, y: w.minY, width: side, height: w.height)
        case .right: return NSRect(x: w.maxX + gap, y: w.minY, width: side, height: w.height)
        case .top: return NSRect(x: w.minX, y: w.minY - strip - gap, width: w.width, height: strip)
        case .bottom: return NSRect(x: w.minX, y: w.maxY + gap, width: w.width, height: strip)
        case .none: return .zero
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let w = windowRect
        let body = NSBezierPath(roundedRect: w, xRadius: 6, yRadius: 6)
        FlyoutColors.background.setFill()
        body.fill()
        FlyoutColors.field.setFill()
        body.fill()

        // Title bar with traffic lights, then a tab strip.
        let titleBar = NSRect(x: w.minX, y: w.minY, width: w.width, height: 12)
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: w.minX + 6 + CGFloat(i) * 7, y: titleBar.midY - 2.5, width: 5, height: 5)).fill()
        }
        FlyoutColors.line.setFill()
        for i in 0..<3 {
            let tab = NSRect(x: w.minX + 30 + CGFloat(i) * 34, y: titleBar.minY + 3, width: 30, height: 6)
            NSBezierPath(roundedRect: tab, xRadius: 2, yRadius: 2).fill()
        }
        NSRect(x: w.minX, y: titleBar.maxY, width: w.width, height: 1).fill()

        FlyoutColors.line.setStroke()
        let edge = NSBezierPath(roundedRect: w.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
        edge.lineWidth = 1
        edge.stroke()

        if let hoveredEdge, hoveredEdge != dock { drawDock(hoveredEdge, alpha: 0.3) }
        if dock != .none { drawDock(dock, alpha: 1) }

        if isFocused, let focusedEdge {
            accent.setStroke()
            let ring = NSBezierPath(roundedRect: dockRect(focusedEdge).insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func drawDock(_ edge: BrowserDock, alpha: CGFloat) {
        let rect = dockRect(edge)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        accent.withAlphaComponent(0.28 * alpha).setFill()
        path.fill()
        accent.withAlphaComponent(alpha).setStroke()
        path.lineWidth = 1
        path.stroke()
        accent.withAlphaComponent(0.7 * alpha).setFill()
        if edge.isSidebar {
            // A few rows of links.
            for i in 0..<4 {
                NSRect(x: rect.minX + 5, y: rect.minY + 7 + CGFloat(i) * 8, width: rect.width - 10, height: 3).fill()
            }
        } else {
            // A few tabs.
            for i in 0..<4 {
                let tab = NSRect(x: rect.minX + 6 + CGFloat(i) * 30, y: rect.minY + 2.5, width: 24, height: rect.height - 5)
                guard tab.maxX < rect.maxX - 4 else { break }
                NSBezierPath(roundedRect: tab, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredEdge = Self.edge(at: convert(event.locationInWindow, from: nil), window: windowRect)
    }

    override func mouseExited(with event: NSEvent) { hoveredEdge = nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let edge = Self.edge(at: convert(event.locationInWindow, from: nil), window: windowRect) else { return }
        choose(edge)
    }

    override func resetCursorRects() {
        for edge in Self.edges { addCursorRect(dockRect(edge).union(zoneRect(edge)), cursor: .pointingHand) }
    }

    /// The clickable part of the window for `edge`, for cursors and VoiceOver frames.
    private func zoneRect(_ edge: BrowserDock) -> NSRect {
        let w = windowRect
        let t = 0.28 * min(w.width, w.height)
        switch edge {
        case .left: return NSRect(x: w.minX, y: w.minY, width: t, height: w.height)
        case .right: return NSRect(x: w.maxX - t, y: w.minY, width: t, height: w.height)
        case .top: return NSRect(x: w.minX, y: w.minY, width: w.width, height: t)
        case .bottom: return NSRect(x: w.minX, y: w.maxY - t, width: w.width, height: t)
        case .none: return .zero
        }
    }

    // MARK: Keyboard

    /// Clicks don't move focus (as with system buttons); Tab does.
    override var acceptsFirstResponder: Bool { NSApplication.shared.currentEvent?.type != .leftMouseDown }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        if focusedEdge == nil { focusedEdge = dock == .none ? .left : dock }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: handleKey(.up)
        case 125: handleKey(.down)
        case 123: handleKey(.left)
        case 124: handleKey(.right)
        case 49, 36, 76: handleKey(.select)
        case 51, 117: handleKey(.clear)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { edgeElements }

    fileprivate func accessibilityFrame(for edge: BrowserDock) -> NSRect {
        dockRect(edge).union(zoneRect(edge))
    }

    static func accessibilityLabel(_ edge: BrowserDock) -> String {
        switch edge {
        case .left: return "Sidebar on the left"
        case .right: return "Sidebar on the right"
        case .top: return "Tabline on top"
        case .bottom: return "Tabline at the bottom"
        case .none: return "Not attached"
        }
    }
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
        setAccessibilityLabel(BrowserDockPicker.accessibilityLabel(edge))
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
