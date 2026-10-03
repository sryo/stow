import AppKit

/// A borderless child panel that floats beside the rail, like the Elastic folder flyout:
/// a 12pt-rounded card with a hairline edge and an arrow pointing back at what opened
/// it. It never widens the main window and flips sides when the screen runs out.
@MainActor
final class RailFlyoutPanel: NSPanel {
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

    /// Shows `view` (sized `size`) beside `rail`, its top `topInset` above `anchor`'s
    /// middle, with the arrow on that middle. All rects are in screen coordinates.
    func present(_ view: NSView, size: NSSize, anchor: NSRect, rail: NSRect, topInset: CGFloat, parent: NSWindow) {
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rail
        let depth = showsArrow ? Self.arrowDepth : 0
        side = FlyoutPlacement.side(width: size.width, rail: rail, screen: screen)
        let x = FlyoutPlacement.originX(side: side, width: size.width, rail: rail)
        let v = FlyoutPlacement.vertical(height: size.height, anchorMidY: anchor.midY, topInset: topInset, screen: screen)
        let frame = NSRect(x: side == .right ? x - depth : x, y: v.minY, width: size.width + depth, height: size.height)

        if content !== view {
            content?.removeFromSuperview()
            chrome.addSubview(view)
            content = view
        }
        chrome.arrowSide = side
        chrome.arrowFromTop = v.arrowFromTop
        view.frame = NSRect(x: side == .right ? depth : 0, y: 0, width: size.width, height: size.height)
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
    var arrowSide: FlyoutPlacement.Side = .right { didSet { needsDisplay = true } }
    var arrowFromTop: CGFloat = 18 { didSet { needsDisplay = true } }
    var showsArrow = true { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let depth = showsArrow ? RailFlyoutPanel.arrowDepth : 0
        var card = bounds
        card.size.width -= depth
        if arrowSide == .right { card.origin.x += depth }
        card = card.insetBy(dx: 0.5, dy: 0.5)
        let path = Self.outline(card: card, radius: cornerRadius, arrowLeft: arrowSide == .right, arrowY: arrowFromTop, depth: depth, half: 7)
        FlyoutColors.background.setFill()
        path.fill()
        FlyoutColors.line.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// A rounded rect with an optional triangular arrow on its left or right edge.
    static func outline(card r: NSRect, radius: CGFloat, arrowLeft: Bool, arrowY: CGFloat, depth: CGFloat, half: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let y = min(max(arrowY, r.minY + radius + half), r.maxY - radius - half)
        p.move(to: NSPoint(x: r.minX + radius, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 0)
        if !arrowLeft && depth > 0 {
            p.line(to: NSPoint(x: r.maxX, y: y - half))
            p.line(to: NSPoint(x: r.maxX + depth, y: y))
            p.line(to: NSPoint(x: r.maxX, y: y + half))
        }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
        if arrowLeft && depth > 0 {
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
