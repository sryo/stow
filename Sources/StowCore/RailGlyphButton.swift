import AppKit

// MARK: - Glyph buttons

/// The rail's small drawn controls: the gear and the dashed "+" tile of an empty workspace.
@MainActor
final class RailGlyphButton: FocusableControl {
    enum Glyph { case gear, addTile }

    let glyph: Glyph
    var colors = StowTheme.colors(for: .settingsBackground) { didSet { needsDisplay = true } }
    /// The gear while its app sheet is open.
    var isOn = false { didSet { needsDisplay = true } }
    /// A warning dot on the gear: something in the app sheet needs a permission.
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
        }
        if showsBadge { drawBadge() }
        if isFocused {
            SettingsColors.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    /// The system symbol a glyph draws, when it's one (the gear matches the title row's).
    static func symbolName(for glyph: Glyph) -> String? {
        glyph == .gear ? StowSymbols.settings : nil
    }

    private func drawGear() {
        // The settings symbol centered in the button; "on" adds a 2pt gap and a 1.5pt ink ring.
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        if isOn {
            colors.inkPrimary.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 10.5, y: c.y - 10.5, width: 21, height: 21)).fill()
            colors.surface.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)).fill()
        }
        let pointSize: CGFloat = isHovered ? 13 : 11
        let ink = isOn || isHovered ? colors.inkPrimary : colors.inkSecondary
        guard let name = Self.symbolName(for: .gear),
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: c.x - symbol.size.width / 2, y: c.y - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
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

    private func drawBadge() {
        let badge = NSRect(x: bounds.maxX - 3 - 7, y: 3, width: 7, height: 7)
        colors.surface.setFill()
        NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
        FlyoutColors.warning.setFill()
        NSBezierPath(ovalIn: badge).fill()
    }
}

/// The one flipped container for the rail, Settings and their flyouts.
class RailFlippedView: NSView {
    override var isFlipped: Bool { true }
}
