import AppKit
import StowShared

/// The one workspace dot: filled with the workspace's `colorId.color`, edged with
/// `SettingsColors.edge` (the hairline tuned for 3:1 in both appearances), and, for the
/// current or chosen one, ringed by a gap and an outer ring. Rail dots, editor swatches,
/// menu images and flyout rows all draw through it.
enum WorkspaceDot {
    enum Style {
        case plain
        /// An outer `ring` with a `gap` between it and the dot.
        case ringed(ring: NSColor, gap: NSColor)
    }

    /// The ring's outer edge sits this far outside the dot; the gap ends at `gapWidth`.
    static let ringOutset: CGFloat = 3.5
    static let gapWidth: CGFloat = 2
    static let edgeWidth: CGFloat = 1

    /// The outer ring and the gap inside it, for a dot in `rect`.
    static func rings(around rect: NSRect) -> (ring: NSRect, gap: NSRect) {
        (rect.insetBy(dx: -ringOutset, dy: -ringOutset), rect.insetBy(dx: -gapWidth, dy: -gapWidth))
    }

    /// Draws a dot filling `rect` into the current context.
    static func draw(in rect: NSRect, color: NSColor, style: Style = .plain) {
        draw(in: rect, style: style) { dot in
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// Draws a dot whose fill is `fill` (the conic Custom color swatch), with the same rings and edge.
    static func draw(in rect: NSRect, style: Style = .plain, fill: (NSRect) -> Void) {
        if case .ringed(let ring, let gap) = style {
            let r = rings(around: rect)
            ring.setFill()
            NSBezierPath(ovalIn: r.ring).fill()
            gap.setFill()
            NSBezierPath(ovalIn: r.gap).fill()
        }
        fill(rect)
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2))
        edge.lineWidth = edgeWidth
        SettingsColors.edge.setStroke()
        edge.stroke()
    }

    /// A dot image for menus, rendered per appearance when the menu draws.
    static func image(color: NSColor, diameter: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            draw(in: rect, color: color)
            return true
        }
    }

    static func image(_ colorId: WorkspaceColorId, diameter: CGFloat = 12) -> NSImage {
        image(color: colorId.color, diameter: diameter)
    }
}
