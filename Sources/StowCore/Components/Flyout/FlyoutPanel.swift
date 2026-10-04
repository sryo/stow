import AppKit

/// A borderless child panel that floats beside a column or below an anchor, like the
/// Elastic folder flyout: a 12pt-rounded card with a hairline edge and an arrow pointing
/// back at what opened it. It never widens the main window and flips sides when the
/// screen runs out. FlyoutController keeps a stack of them.
@MainActor
final class FlyoutPanel: NSPanel {
    /// Where the card goes relative to its anchor.
    enum Edge {
        /// Beside a column (the rail, a parent flyout, or the whole window), arrow on the
        /// near side.
        case beside(column: NSRect)
        /// Under the anchor, arrow on top (Tabline items, title-bar buttons).
        case below
    }

    static let arrowDepth: CGFloat = 7

    private let chrome = FlyoutChromeView()
    private(set) var content: NSView?
    private(set) var side: FlyoutPlacement.Side = .right
    var onEscape: (() -> Void)?
    private let takesKey: Bool

    init(takesKey: Bool = true) {
        self.takesKey = takesKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = chrome
    }

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    var showsArrow: Bool {
        get { chrome.showsArrow }
        set { chrome.showsArrow = newValue }
    }

    var cornerRadius: CGFloat {
        get { chrome.cornerRadius }
        set { chrome.cornerRadius = newValue }
    }

    /// Shows `view` (sized `size`) at `edge` of `anchor`. Beside a column, the card's top
    /// sits `topInset` above the anchor's middle, with the arrow on that middle. All rects
    /// are in screen coordinates.
    func present(_ view: NSView, size: NSSize, anchor: NSRect, edge: Edge, topInset: CGFloat, parent: NSWindow) {
        let depth = showsArrow ? Self.arrowDepth : 0
        let frame: NSRect
        switch edge {
        case .beside(let column):
            let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? column
            side = FlyoutPlacement.side(width: size.width, rail: column, screen: screen)
            let x = FlyoutPlacement.originX(side: side, width: size.width, rail: column)
            let v = FlyoutPlacement.vertical(height: size.height, anchorMidY: anchor.midY, topInset: topInset, screen: screen)
            frame = NSRect(x: side == .right ? x - depth : x, y: v.minY, width: size.width + depth, height: size.height)
            chrome.arrowEdge = side == .right ? .left : .right
            chrome.arrowOffset = v.arrowFromTop
            view.frame = NSRect(x: side == .right ? depth : 0, y: 0, width: size.width, height: size.height)
        case .below:
            let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
            let b = FlyoutPlacement.below(width: size.width, anchor: anchor, screen: screen)
            frame = NSRect(x: b.minX, y: b.maxY - size.height - depth, width: size.width, height: size.height + depth)
            chrome.arrowEdge = .top
            chrome.arrowOffset = b.arrowFromLeft
            view.frame = NSRect(x: 0, y: depth, width: size.width, height: size.height)
        }

        if content !== view {
            content?.removeFromSuperview()
            chrome.addSubview(view)
            content = view
        }
        setFrame(frame, display: true)
        chrome.needsDisplay = true
        invalidateShadow()
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Draws the card and its arrow in one outline, so the hairline runs around both.
private final class FlyoutChromeView: NSView {
    enum ArrowEdge { case left, right, top }
    var arrowEdge: ArrowEdge = .left { didSet { needsDisplay = true } }
    /// From the card's top for a side arrow, from its left for a top arrow.
    var arrowOffset: CGFloat = 18 { didSet { needsDisplay = true } }
    var showsArrow = true { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let depth = showsArrow ? FlyoutPanel.arrowDepth : 0
        var card = bounds
        switch arrowEdge {
        case .left: card.size.width -= depth; card.origin.x += depth
        case .right: card.size.width -= depth
        case .top: card.size.height -= depth; card.origin.y += depth
        }
        card = card.insetBy(dx: 0.5, dy: 0.5)
        let path = Self.outline(card: card, radius: cornerRadius, arrow: arrowEdge, offset: arrowOffset, depth: depth, half: 7)
        FlyoutColors.background.setFill()
        path.fill()
        FlyoutColors.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A rounded rect with an optional triangular arrow on its left, right or top edge.
    static func outline(card r: NSRect, radius: CGFloat, arrow: ArrowEdge, offset: CGFloat, depth: CGFloat, half: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let y = min(max(r.minY + offset, r.minY + radius + half), r.maxY - radius - half)
        let x = min(max(r.minX + offset, r.minX + radius + half), r.maxX - radius - half)
        p.move(to: NSPoint(x: r.minX + radius, y: r.minY))
        if arrow == .top && depth > 0 {
            p.line(to: NSPoint(x: x - half, y: r.minY))
            p.line(to: NSPoint(x: x, y: r.minY - depth))
            p.line(to: NSPoint(x: x + half, y: r.minY))
        }
        p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 0)
        if arrow == .right && depth > 0 {
            p.line(to: NSPoint(x: r.maxX, y: y - half))
            p.line(to: NSPoint(x: r.maxX + depth, y: y))
            p.line(to: NSPoint(x: r.maxX, y: y + half))
        }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        if arrow == .left && depth > 0 {
            p.line(to: NSPoint(x: r.minX, y: y + half))
            p.line(to: NSPoint(x: r.minX - depth, y: y))
            p.line(to: NSPoint(x: r.minX, y: y - half))
        }
        p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        p.close()
        p.lineJoinStyle = .round
        return p
    }
}
