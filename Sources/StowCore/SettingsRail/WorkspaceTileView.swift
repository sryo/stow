import AppKit

/// A workspace's identity on its own color: a 2×2 favicon mosaic, a letter, or a symbol.
/// Drawn to its bounds, so the same view serves the 36pt rail tile, the editor's 44pt
/// tile and the 26pt minis in the icon picker. Metrics scale from the 36pt tile.
@MainActor
final class WorkspaceTileView: NSView {
    var colorId: WorkspaceColorId = .defaultColor() { didSet { needsDisplay = true } }
    var identity: WorkspaceTileIdentity = .letter("?") { didSet { needsDisplay = true } }
    /// The selected ring: a 2pt gap in `ringGap`, then 1.5pt of `ringInk`, drawn outside
    /// the tile (the view must leave 3.5pt of room around it).
    var ringInset: CGFloat = 0 { didSet { needsDisplay = true } }
    var showsRing = false { didSet { needsDisplay = true } }
    var ringInk: NSColor = .labelColor { didSet { needsDisplay = true } }
    var ringGap: NSColor = .clear { didSet { needsDisplay = true } }
    /// Overrides the corner radius (the grow animation starts round).
    var radiusOverride: CGFloat? { didSet { needsDisplay = true } }

    private static let imageCache = NSCache<NSString, NSImage>()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var tileRect: NSRect { bounds.insetBy(dx: ringInset, dy: ringInset) }

    static func radius(for side: CGFloat) -> CGFloat { side * 11 / 36 }

    override func draw(_ dirtyRect: NSRect) {
        let rect = tileRect
        let s = rect.width / 36
        let radius = radiusOverride ?? Self.radius(for: rect.width)
        if showsRing {
            ringInk.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5), xRadius: radius + 3.5, yRadius: radius + 3.5).fill()
            ringGap.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2).fill()
        }
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        colorId.color.setFill()
        shape.fill()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let ink = StowTheme.colors(for: colorId, tint: .full).light.inkPrimary.platformColor
        switch identity {
        case .mosaic(let links):
            let inset = 4 * s, gap = 2 * s
            let cell = (rect.width - inset * 2 - gap) / 2
            for i in 0..<4 {
                let frame = NSRect(x: rect.minX + inset + CGFloat(i % 2) * (cell + gap),
                                   y: rect.minY + inset + CGFloat(i / 2) * (cell + gap), width: cell, height: cell)
                let r = 4 * s
                if i < links.count, let image = Self.image(for: links[i]) {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r).addClip()
                    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.high])
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    NSColor(white: 0, alpha: 0.12).setFill()
                    NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r).fill()
                }
            }
        case .letter(let letter):
            let size = rect.width * 0.48
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: letter.count > 1 ? size * 0.82 : size, weight: .heavy),
                .foregroundColor: ink, .kern: -0.4 * s,
            ]
            let text = letter as NSString
            let measured = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2), withAttributes: attributes)
        case .symbol(let name):
            let point = rect.width * 0.42
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: point, weight: .semibold))?
                .tinted(ink) {
                let size = image.size
                image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        effectiveAppearance.performAsCurrentDrawingAppearance {
            FlyoutColors.tileEdge.setStroke()
        }
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }

    private static func image(for link: Link) -> NSImage? {
        guard let path = link.faviconPath else { return nil }
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache.setObject(image, forKey: path as NSString)
        return image
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension NSImage {
    /// A template symbol filled with one color.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
