import AppKit

/// Shows the app icon in the Dock with its ribbon in the current workspace color.
/// Geometry mirrors `Resources/IconSource/icon.svg` on its 1024 canvas.
@MainActor
enum DockIconRenderer {

    private static var shownHex: String?

    static func apply(_ colorId: WorkspaceColorId) {
        guard let ribbon = DockIconTint.ribbonColor(for: colorId) else {
            guard shownHex != nil else { return }
            shownHex = nil
            NSApp.applicationIconImage = nil
            return
        }
        guard ribbon.hex != shownHex else { return }
        shownHex = ribbon.hex
        NSApp.applicationIconImage = image(ribbon: ribbon.platformColor)
    }

    static func image(ribbon: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!

            // Shadow offsets ignore the flipped CTM, so a downward offset is negative.
            let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                              cornerWidth: 185, cornerHeight: 185, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(tile)
            ctx.setFillColor(NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(tile)
            ctx.clip()
            let gradient = CGGradient(colorsSpace: space, colors: [
                NSColor(srgbRed: 0.165, green: 0.165, blue: 0.180, alpha: 1).cgColor,
                NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
            ctx.restoreGState()

            let window = CGRect(x: 452, y: 336, width: 368, height: 352)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: window, cornerWidth: 44, cornerHeight: 44, transform: nil))
            ctx.clip()
            ctx.setFillColor(NSColor(srgbRed: 0.725, green: 0.741, blue: 0.776, alpha: 1).cgColor)
            ctx.fill(window)
            ctx.setFillColor(NSColor(srgbRed: 0.227, green: 0.227, blue: 0.247, alpha: 1).cgColor)
            ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 84))
            ctx.restoreGState()

            // Ribbon: 222 wide with rounded top corners and a V notch 124 deep at the tail.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 262, y: 828))
            path.addLine(to: CGPoint(x: 262, y: 224))
            path.addArc(tangent1End: CGPoint(x: 262, y: 196), tangent2End: CGPoint(x: 290, y: 196), radius: 28)
            path.addArc(tangent1End: CGPoint(x: 512, y: 196), tangent2End: CGPoint(x: 512, y: 224), radius: 28)
            path.addLine(to: CGPoint(x: 512, y: 828))
            path.addLine(to: CGPoint(x: 387, y: 704))
            path.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 16, height: -8), blur: 32,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(ribbon.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            return true
        }
    }
}
