import AppKit

/// Colors, type and text drawing for "Where Stow lives", from the illustrated-cards design.
/// The cards sit on the app sheet's popover (`.flyout`) or on the Settings page (`.page`),
/// whose tokens differ slightly; the illustration palette is shared.
@MainActor
enum PlacementColors {
    enum Surface { case flyout, page }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    private static func black(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }

    // --c-ink, --c-ink2, --c-field, --c-hover, --c-bg, --c-line
    static func ink(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0x16191C), hex(0xEEF0F2)) : FlyoutColors.ink
    }

    static func inkSecondary(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0x5B6066), hex(0x9AA1A8)) : FlyoutColors.inkSecondary
    }

    static func field(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(black(0.06), white(0.08)) : dynamic(black(0.075), white(0.085))
    }

    static func hover(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0xF2F1ED), hex(0x2C3034)) : dynamic(black(0.065), white(0.075))
    }

    /// What the card sits on: the gap inside the selection ring and around badges.
    static func background(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0xFFFFFF), hex(0x24272B)) : SettingsColors.surface
    }

    static func line(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0x14181C, 0.11), white(0.1)) : FlyoutColors.ink.withAlphaComponent(0.14)
    }

    /// Allow…: raised on the popover, the page's base color on the page.
    static func button(_ surface: Surface) -> NSColor {
        surface == .flyout ? dynamic(hex(0xFFFFFF), hex(0x3A3F44)) : dynamic(hex(0xFFFFFF), hex(0x111618))
    }

    static let warning = dynamic(hex(0xB4560A), hex(0xF0A35E))
    static let warningFill = dynamic(NSColor(srgbRed: 220 / 255, green: 120 / 255, blue: 20 / 255, alpha: 0.10),
                                     NSColor(srgbRed: 240 / 255, green: 163 / 255, blue: 94 / 255, alpha: 0.12))
    /// The "!" on an amber dot: white in light mode, the popover's dark in dark mode.
    static let onWarning = dynamic(hex(0xFFFFFF), hex(0x24272B))
    static let focus = dynamic(NSColor(srgbRed: 47 / 255, green: 127 / 255, blue: 216 / 255, alpha: 0.55),
                               NSColor(srgbRed: 90 / 255, green: 160 / 255, blue: 240 / 255, alpha: 0.7))

    // Illustration palette (--w-*)
    static let wall = dynamic(hex(0xDDE6EA), hex(0x1D2731))
    static let wall2 = dynamic(hex(0xECE3D6), hex(0x29222E))
    static let browser = dynamic(hex(0xFFFFFF), hex(0x33383E))
    static let bar = dynamic(hex(0xE4E4E2), hex(0x43494F))
    static let textLine = dynamic(hex(0xE9ECEE), hex(0x3C4248))
    static let intruder = dynamic(hex(0xB3ABE9), hex(0x5D5596))
    static let intruder2 = dynamic(hex(0x8F86D6), hex(0x8279C4))
    static let stow = dynamic(hex(0x7FE4F1), hex(0x2C9FB0))
    static let stowInk = dynamic(hex(0x0C2328, 0.38), NSColor(srgbRed: 229 / 255, green: 238 / 255, blue: 240 / 255, alpha: 0.5))
    static let edge = dynamic(hex(0x0C2328, 0.16), NSColor(srgbRed: 229 / 255, green: 238 / 255, blue: 240 / 255, alpha: 0.2))
    static let cursor = dynamic(hex(0x16191C), hex(0xF2F4F6))
}

@MainActor
enum PlacementFonts {
    /// The system font at a CSS weight (550, 650…): SF's weight axis takes any value.
    static func ui(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard weight != 400 else { return base }
        let descriptor = base.fontDescriptor.addingAttributes([.variation: [NSNumber(value: 0x7767_6874): weight]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// One run of text for PlacementText.
struct PlacementRun {
    var text: String
    var font: NSFont
    var color: NSColor
    var kern: CGFloat = 0
}

/// Text laid out like the design's CSS: a fixed line height with the glyphs centered in
/// each line (CSS half-leading), wrapped at a width, optionally flowing around a box in
/// the top-right corner (a CSS float).
@MainActor
final class PlacementText: NSView {
    struct Paragraph {
        var runs: [PlacementRun]
        var lineHeight: CGFloat
        /// Space above this paragraph (CSS margin-top).
        var spacingBefore: CGFloat = 0
    }

    var paragraphs: [Paragraph] = [] { didSet { needsDisplay = true } }
    var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }
    private var wrapSlack: CGFloat { alignment == .left ? 0.5 : 0 }
    /// A box in the top-right corner the first lines wrap around.
    var exclusion: NSSize? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var plainText: String { paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n") }

    private func storage() -> NSTextStorage {
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = paragraph.lineHeight
            style.maximumLineHeight = paragraph.lineHeight
            style.paragraphSpacingBefore = index == 0 ? 0 : paragraph.spacingBefore
            style.lineBreakMode = .byWordWrapping
            style.alignment = alignment
            for (runIndex, run) in paragraph.runs.enumerated() {
                // TextKit puts a line's extra height above the glyphs; CSS splits it.
                let natural = run.font.ascender - run.font.descender
                var text = run.text
                if runIndex == paragraph.runs.count - 1, index < paragraphs.count - 1 { text += "\n" }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: run.font, .foregroundColor: run.color, .paragraphStyle: style,
                    // Plus half a point: Chrome rounds the baseline up, measured against the design.
                    .baselineOffset: (paragraph.lineHeight - natural) / 2 + 0.5,
                ]
                // An explicit kern of 0 would turn off the font's own kerning.
                if run.kern != 0 { attributes[.kern] = run.kern }
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return NSTextStorage(attributedString: result)
    }

    private func layout(width: CGFloat) -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
        let textStorage = storage()
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        // Chrome fits a line that's a hair over the width (fractional pixels); the slack
        // keeps lines breaking where the design's do.
        let container = NSTextContainer(size: NSSize(width: width + wrapSlack, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if let exclusion {
            container.exclusionPaths = [NSBezierPath(rect: NSRect(x: width - exclusion.width, y: 0,
                                                                  width: exclusion.width + wrapSlack + 1,
                                                                  height: exclusion.height))]
        }
        manager.addTextContainer(container)
        textStorage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return (manager, container, textStorage)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !paragraphs.isEmpty else { return 0 }
        // The storage owns the layout manager's text; keep it alive while measuring.
        let (manager, container, textStorage) = layout(width: width)
        return withExtendedLifetime(textStorage) { ceil(manager.usedRect(for: container).height) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !paragraphs.isEmpty else { return }
        let (manager, container, textStorage) = layout(width: bounds.width)
        withExtendedLifetime(textStorage) {
            let range = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: range, at: .zero)
            manager.drawGlyphs(forGlyphRange: range, at: .zero)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension NSView {
    /// A dynamic color resolved for this view's appearance, for Core Graphics drawing.
    @MainActor
    func placementCG(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}
