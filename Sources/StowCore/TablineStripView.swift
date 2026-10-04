import AppKit

/// One top-level entry of the strip: a saved site, or a folder collapsed into a group.
enum TablineEntry {
    case link(Link)
    case group(Folder, links: [Link])

    var links: [Link] {
        switch self {
        case .link(let link): return [link]
        case .group(_, let links): return links
        }
    }
}

/// The page in front of the front browser when it isn't saved in the workspace.
struct TablineGhost: Equatable {
    let url: URL
    let title: String
    let host: String

    /// "Stow MDN": the site's name from the page title ("MDN · Popover API", "Linear – Plan"),
    /// or the host when the title has no short leading segment.
    var label: String {
        let separators = [" · ", " – ", " — ", " - ", " | ", ": "]
        let first = separators.reduce(title) { part, sep in part.components(separatedBy: sep).first ?? part }
            .trimmingCharacters(in: .whitespaces)
        let name = !first.isEmpty && first.count <= 20 && first != title ? first : host
        return "Stow \(name)"
    }
}

/// Everything the strip draws. The controller derives it from the workspace and the browser state.
struct TablineStripModel {
    var name = ""
    var colorId: WorkspaceColorId = .defaultColor()
    var entries: [TablineEntry] = []
    var raisedIndex: Int?
    var liveIndices: Set<Int> = []
    var ghost: TablineGhost?
    var pocketCount = 0
}

/// Strip colors: the workspace color mixed into a near-white (light) or near-black (dark)
/// base, the way the approved mockup mixes `--ws` into `--strip-base`.
struct TablinePalette {
    let surface: NSColor
    let ink: NSColor
    let raised: NSColor

    init(colorId: WorkspaceColorId, dark: Bool) {
        typealias RGB = StowTheme.RGB
        let hue = RGB(colorId.color)
        let base = dark ? RGB(hex: "#1E1F22")! : RGB(hex: "#F7F6F3")!
        let surface = base.mix(hue, dark ? 0.22 : 0.40)
        let darkInk = RGB(hex: "#1D1D20")!, lightInk = RGB(hex: "#EDEDF0")!
        let ink = darkInk.contrast(with: surface) >= lightInk.contrast(with: surface) ? darkInk : lightInk
        self.surface = surface.platformColor
        self.ink = ink.platformColor
        self.raised = (dark ? RGB(hex: "#34353A")! : RGB.white).platformColor
    }
}

/// The Tabline's name for the shared site glyph.
typealias TablineGlyph = SiteGlyph

/// Drawing for the shared site glyph: the favicon, or the letter tile when there is none.
extension SiteGlyph {
    nonisolated(unsafe) private static var imageCache: [String: NSImage] = [:]

    static func favicon(_ path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache[path] = image
        return image
    }

    /// Draws into the current context. `ring` paints a halo around the tile, used where tiles overlap.
    static func draw(title: String, url: String, faviconPath: String?, in rect: NSRect, ring: NSColor? = nil) {
        let radius = max(3, (rect.width * 0.26).rounded())
        if let ring {
            ring.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5).fill()
        }
        if let image = favicon(faviconPath) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let host = host(of: url)
        drawTile(letters: letters(title: title, host: host), host: host, in: rect)
    }

    /// The letter tile alone: a rounded square in the host's color with a hairline edge.
    static func drawTile(letters: String, host: String, in rect: NSRect) {
        let radius = max(3, (rect.width * 0.26).rounded())
        tileColor(for: host).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let ringPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        ringPath.lineWidth = 0.5
        ringPath.stroke()
        let text = letters as NSString
        let scale: CGFloat = letters.count > 1 ? 0.46 : 0.62
        let font = NSFont.systemFont(ofSize: max(5, (rect.height * scale).rounded()), weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    /// A letter tile image for a site with no favicon, sized for list rows and tiles.
    static func tileImage(title: String, host: String, size: CGFloat) -> NSImage {
        let host = normalizedHost(host)
        let letters = letters(title: title, host: host)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            drawTile(letters: letters, host: host, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A 16pt image for menus.
    static func menuImage(title: String, url: String, faviconPath: String?) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: true) { rect in
            draw(title: title, url: url, faviconPath: faviconPath, in: rect)
            return true
        }
    }
}

/// The tab row. It draws itself (no subviews) so every measurement can follow the mockup:
/// 32pt strip, 24pt items, 14pt glyphs, and three width tiers (full names, short names,
/// icons only) before the trailing tabs fold into a "+n" overflow.
final class TablineStripView: NSView {
    enum Kind: Equatable { case chip, tab(Int), group(Int), ghost, overflow, pocket }
    enum Tier { case full, short, icon }

    /// Called on click with the clicked part and its rect in this view's (flipped) coordinates.
    var onActivate: ((Kind, NSRect) -> Void)?

    private(set) var model = TablineStripModel()
    private(set) var hiddenEntryIndices: [Int] = []
    /// A thin colored bar with nothing drawn on it: the full-screen "lip".
    var isLip = false { didSet { if isLip != oldValue { needsDisplay = true } } }

    private var items: [(kind: Kind, rect: NSRect)] = []
    private var tier: Tier = .full
    private var hovered: Kind?
    private var pressed: Kind?

    private enum M {
        static let pad: CGFloat = 5
        static let gap: CGFloat = 2
        static let itemH: CGFloat = 24
        static let radius: CGFloat = 10
        static let itemRadius: CGFloat = 6
        static let glyph: CGFloat = 14
        static let tabMax: CGFloat = 150
        static let shortTitleMax: CGFloat = 52
        static let ghostTitleMax: CGFloat = 170
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ model: TablineStripModel) {
        self.model = model
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var palette: TablinePalette {
        TablinePalette(colorId: model.colorId, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    // MARK: - Fonts and measuring

    private static func font(_ weight: NSFont.Weight, _ size: CGFloat = 12) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    private static func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    private var chipWidth: CGFloat {
        6 + M.glyph + 6 + Self.width(model.name, Self.font(.bold)) + 6 + Self.width("▾", Self.font(.regular, 9)) + 8
    }

    private func entryWidth(_ i: Int, _ tier: Tier) -> CGFloat {
        switch model.entries[i] {
        case .link(let link):
            let font = Self.font(model.raisedIndex == i ? .semibold : .medium)
            switch tier {
            case .full: return min(M.tabMax, 6 + M.glyph + 6 + Self.width(link.title, font) + 9)
            case .short: return 5 + M.glyph + 6 + min(M.shortTitleMax, Self.width(link.title, font)) + 7
            case .icon: return 5 + M.glyph + 5
            }
        case .group(let folder, let links):
            let stack = stackWidth(min(3, links.count))
            switch tier {
            case .full: return 6 + stack + 5 + Self.width(folder.name, Self.font(.semibold)) + 5 + Self.width("\(links.count)", Self.font(.semibold)) + 8
            case .short: return 6 + stack + 5 + Self.width("\(links.count)", Self.font(.semibold)) + 8
            case .icon: return 6 + stack + 8
            }
        }
    }

    private func stackWidth(_ n: Int) -> CGFloat { n <= 0 ? M.glyph : M.glyph + CGFloat(n - 1) * (M.glyph - 3) }

    private func ghostWidth(_ tier: Tier) -> CGFloat {
        guard let ghost = model.ghost else { return 0 }
        let base = 1 + 5 + Self.width("+", Self.font(.heavy)) + 5 + M.glyph
        if tier != .full { return base + 8 + 1 }
        return base + 5 + min(M.ghostTitleMax, Self.width(ghost.label, Self.font(.semibold))) + 8 + 1
    }

    private func pocketWidth(_ tier: Tier) -> CGFloat {
        guard model.pocketCount > 0 else { return 0 }
        let glyph = 6 + Self.width("◫", Self.font(.regular)) + 6
        return tier == .icon ? glyph : glyph + 4 + Self.width("\(model.pocketCount)", Self.font(.semibold, 10))
    }

    private func overflowWidth(_ n: Int) -> CGFloat { 6 + Self.width("+\(n)", Self.font(.bold)) + 6 }

    // MARK: - Layout

    private func relayout() {
        items = []
        hiddenEntryIndices = []
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        let y = ((h - M.itemH) / 2).rounded()
        func rect(_ x: CGFloat, _ width: CGFloat) -> NSRect { NSRect(x: x, y: y, width: width, height: M.itemH) }

        // chip, gap, sep (4 + 1 + 4), gap, tabs (3pt leading inset)
        let tabsStart = M.pad + chipWidth + M.gap + 9 + M.gap + 3
        func trailing(_ t: Tier) -> CGFloat {
            var total = M.gap + 4 + M.pad   // gap to spacer, spacer's minimum, right padding
            if model.ghost != nil { total += M.gap + ghostWidth(t) }
            if model.pocketCount > 0 { total += M.gap + pocketWidth(t) }
            return total
        }
        func entriesWidth(_ t: Tier, count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            return (0..<count).reduce(0) { $0 + entryWidth($1, t) } + CGFloat(count - 1) * M.gap
        }

        var visible = model.entries.count
        tier = .icon
        for t in [Tier.full, .short, .icon] where tabsStart + entriesWidth(t, count: visible) + trailing(t) <= w {
            tier = t
            break
        }
        if tier == .icon {
            while visible > 0, tabsStart + entriesWidth(.icon, count: visible) + M.gap + overflowWidth(model.entries.count - visible) + trailing(.icon) > w {
                visible -= 1
            }
        }
        hiddenEntryIndices = Array(visible..<model.entries.count)

        // Between full and short, hand the spare room back to the tabs that were cut most,
        // so names only shorten as far as the width demands.
        var widths = (0..<visible).map { entryWidth($0, tier) }
        if tier == .short {
            let full = (0..<visible).map { entryWidth($0, .full) }
            var spare = w - (tabsStart + entriesWidth(.short, count: visible) + trailing(.short))
            var open = Set((0..<visible).filter { full[$0] > widths[$0] })
            while spare > 0.5, !open.isEmpty {
                let share = spare / CGFloat(open.count)
                for i in open {
                    let grow = min(share, full[i] - widths[i])
                    widths[i] += grow
                    spare -= grow
                    if full[i] - widths[i] < 0.5 { open.remove(i) }
                }
            }
            widths = widths.map { $0.rounded(.down) }
        }

        items.append((.chip, rect(M.pad, chipWidth)))
        var x = tabsStart
        for i in 0..<visible {
            let width = widths[i]
            items.append((model.entries[i].isGroup ? .group(i) : .tab(i), rect(x, width)))
            x += width + M.gap
        }
        if !hiddenEntryIndices.isEmpty {
            let width = overflowWidth(hiddenEntryIndices.count)
            items.append((.overflow, rect(x, width)))
            x += width + M.gap
        }
        if model.ghost != nil {
            items.append((.ghost, rect(x, ghostWidth(tier))))
        }
        if model.pocketCount > 0 {
            let width = pocketWidth(tier)
            items.append((.pocket, rect(w - M.pad - width, width)))
        }
        needsDisplay = true
    }

    func rect(of kind: Kind) -> NSRect? { items.first { $0.kind == kind }?.rect }

    // MARK: - Accessibility

    /// The strip draws its parts, so VoiceOver gets one button element per drawn rect.
    private final class PartElement: NSAccessibilityElement {
        var onPress: (() -> Void)?
        override func accessibilityPerformPress() -> Bool {
            onPress?()
            return true
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Tabline, \(model.name)" }

    override func accessibilityChildren() -> [Any]? {
        guard !isLip else { return [] }
        return items.map { item in
            let element = PartElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(accessibilityLabel(for: item.kind))
            element.setAccessibilityFrameInParentSpace(item.rect)
            element.onPress = { [weak self] in self?.onActivate?(item.kind, item.rect) }
            return element
        }
    }

    private func accessibilityLabel(for kind: Kind) -> String {
        func open(_ i: Int) -> String { model.liveIndices.contains(i) ? ", open in browser" : "" }
        switch kind {
        case .chip: return "\(model.name), switch workspace"
        case .tab(let i):
            guard case .link(let link) = model.entries[i] else { return "" }
            let host = TablineGlyph.host(of: link.url)
            return "\(link.title), link\(host.isEmpty ? "" : ", \(host)")\(open(i))"
        case .group(let i):
            guard case .group(let folder, let links) = model.entries[i] else { return "" }
            return "\(folder.name), folder, \(links.count) sites\(open(i))"
        case .ghost: return model.ghost.map { "Stow this page, \($0.host), to \(model.name)" } ?? ""
        case .overflow: return "\(hiddenEntryIndices.count) more"
        case .pocket: return "Tasks and snippets, \(model.pocketCount)"
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let p = palette
        if isLip {
            p.surface.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            return
        }
        p.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: M.radius, yRadius: M.radius).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: M.radius, yRadius: M.radius)
        ring.lineWidth = 0.5
        ring.stroke()

        // separator after the chip
        let sepX = M.pad + chipWidth + M.gap + 4
        p.ink.withAlphaComponent(0.18).setFill()
        NSRect(x: sepX, y: (bounds.height - 16) / 2, width: 1, height: 16).fill()

        for item in items {
            switch item.kind {
            case .chip: drawChip(item.rect, p)
            case .tab(let i): drawTab(i, item.rect, p)
            case .group(let i): drawGroup(i, item.rect, p)
            case .ghost: drawGhost(item.rect, p)
            case .overflow: drawOverflow(item.rect, p)
            case .pocket: drawTool("◫", count: tier == .icon ? nil : model.pocketCount, item.rect, p, kind: .pocket)
            }
        }
    }

    private func fillItem(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: M.itemRadius, yRadius: M.itemRadius).fill()
    }

    private func hoverFill(_ kind: Kind, _ rect: NSRect, _ p: TablinePalette, rest: CGFloat = 0, hover: CGFloat = 0.09) {
        let alpha = pressed == kind ? hover + 0.05 : (hovered == kind ? hover : rest)
        if alpha > 0 { fillItem(rect, p.ink.withAlphaComponent(alpha)) }
    }

    @discardableResult
    private func drawText(_ s: String, at x: CGFloat, midY: CGFloat, font: NSFont, color: NSColor, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let size = (s as NSString).size(withAttributes: attrs)
        let width = min(ceil(size.width), maxWidth)
        (s as NSString).draw(with: NSRect(x: x, y: midY - size.height / 2, width: width, height: size.height),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        return width
    }

    private func glyphRect(x: CGFloat, in rect: NSRect) -> NSRect {
        NSRect(x: x, y: (rect.midY - M.glyph / 2).rounded(), width: M.glyph, height: M.glyph)
    }

    private func drawChip(_ rect: NSRect, _ p: TablinePalette) {
        hoverFill(.chip, rect, p)
        drawRibbon(in: glyphRect(x: rect.minX + 6, in: rect), color: p.ink)
        var x = rect.minX + 6 + M.glyph + 6
        x += drawText(model.name, at: x, midY: rect.midY, font: Self.font(.bold), color: p.ink) + 6
        drawText("▾", at: x, midY: rect.midY, font: Self.font(.regular, 9), color: p.ink.withAlphaComponent(0.5))
    }

    /// The Stow bookmark ribbon with two eyes, from the mockup's 16pt SVG.
    private func drawRibbon(in rect: NSRect, color: NSColor) {
        let s = rect.width / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        let path = NSBezierPath()
        path.move(to: pt(3.5, 1.5))
        path.line(to: pt(12.5, 1.5))
        path.line(to: pt(12.5, 14.5))
        path.line(to: pt(8, 11.3))
        path.line(to: pt(3.5, 14.5))
        path.close()
        path.lineWidth = 1.5 * s
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
        color.setFill()
        for cx in [6.4, 9.6] {
            let c = pt(cx, 6.3), r = 0.95 * s
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    private func drawTab(_ i: Int, _ rect: NSRect, _ p: TablinePalette) {
        guard case .link(let link) = model.entries[i] else { return }
        let raised = model.raisedIndex == i
        if raised {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.set()
            fillItem(rect, p.raised)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -0.25, dy: -0.25), xRadius: M.itemRadius, yRadius: M.itemRadius)
            ring.lineWidth = 0.5
            ring.stroke()
        } else {
            hoverFill(.tab(i), rect, p)
        }
        let leading: CGFloat = tier == .full ? 6 : 5
        let glyph = glyphRect(x: rect.minX + leading, in: rect)
        TablineGlyph.draw(title: link.title, url: link.url, faviconPath: link.faviconPath, in: glyph)
        if tier != .icon {
            let x = glyph.maxX + 6
            let trailing: CGFloat = tier == .full ? 9 : 7
            drawText(link.title, at: x, midY: rect.midY, font: Self.font(raised ? .semibold : .medium), color: p.ink,
                     maxWidth: rect.maxX - trailing - x)
        }
        if model.liveIndices.contains(i) {
            let barX = tier == .icon ? rect.midX - 4 : rect.minX + 9
            p.ink.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: rect.maxY - 1.5 - 2, width: 8, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawGroup(_ i: Int, _ rect: NSRect, _ p: TablinePalette) {
        guard case .group(let folder, let links) = model.entries[i] else { return }
        if model.raisedIndex == i {
            fillItem(rect, p.raised)
        } else {
            hoverFill(.group(i), rect, p, rest: 0.06, hover: 0.12)
        }
        let ring = p.surface.blended(withFraction: 0.06, of: p.ink) ?? p.surface
        var x = rect.minX + 6
        let stacked = Array(links.prefix(3))
        if stacked.isEmpty {
            let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            folderImage?.draw(in: glyphRect(x: x, in: rect))
        }
        for link in stacked {
            TablineGlyph.draw(title: link.title, url: link.url, faviconPath: link.faviconPath, in: glyphRect(x: x, in: rect),
                              ring: link.id == stacked.first?.id ? nil : ring)
            x += M.glyph - 3
        }
        x = rect.minX + 6 + stackWidth(stacked.count) + 5
        guard tier != .icon else { return }
        // The name shows whenever the waterfill gave the group room for it next to the count.
        let countWidth = Self.width("\(links.count)", Self.font(.semibold))
        let nameRoom = rect.maxX - 8 - countWidth - 5 - x
        if tier == .full || nameRoom >= 24 {
            x += drawText(folder.name, at: x, midY: rect.midY, font: Self.font(.semibold), color: p.ink, maxWidth: nameRoom) + 5
        }
        drawText("\(links.count)", at: x, midY: rect.midY, font: Self.font(.semibold), color: p.ink.withAlphaComponent(0.55))
    }

    private func drawGhost(_ rect: NSRect, _ p: TablinePalette) {
        guard let ghost = model.ghost else { return }
        let active = hovered == .ghost || pressed == .ghost
        let alpha: CGFloat = active ? 1 : 0.85
        if active { fillItem(rect, p.ink.withAlphaComponent(0.07)) }
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: M.itemRadius, yRadius: M.itemRadius)
        border.lineWidth = 1
        border.setLineDash([3, 2], count: 2, phase: 0)
        p.ink.withAlphaComponent(0.40 * alpha).setStroke()
        border.stroke()
        let ink = p.ink.withAlphaComponent(alpha)
        var x = rect.minX + 1 + 5
        x += drawText("+", at: x, midY: rect.midY, font: Self.font(.heavy), color: ink) + 5
        let glyph = glyphRect(x: x, in: rect)
        TablineGlyph.draw(title: ghost.title, url: ghost.url.absoluteString, faviconPath: nil, in: glyph)
        if tier == .full {
            let tx = glyph.maxX + 5
            drawText(ghost.label, at: tx, midY: rect.midY, font: Self.font(.semibold), color: ink, maxWidth: rect.maxX - 9 - tx)
        }
    }

    private func drawOverflow(_ rect: NSRect, _ p: TablinePalette) {
        hoverFill(.overflow, rect, p)
        drawText("+\(hiddenEntryIndices.count)", at: rect.minX + 6, midY: rect.midY, font: Self.font(.bold), color: p.ink.withAlphaComponent(0.7))
    }

    private func drawTool(_ glyph: String, count: Int?, _ rect: NSRect, _ p: TablinePalette, kind: Kind) {
        let active = hovered == kind || pressed == kind
        hoverFill(kind, rect, p)
        let ink = p.ink.withAlphaComponent(active ? 1 : 0.75)
        var x = rect.minX + 6
        x += drawText(glyph, at: x, midY: rect.midY, font: Self.font(.regular), color: ink)
        if let count {
            drawText("\(count)", at: x + 4, midY: rect.midY, font: Self.font(.semibold, 10), color: ink.withAlphaComponent(0.7 * (active ? 1 : 0.75)))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func kind(at event: NSEvent) -> Kind? {
        let point = convert(event.locationInWindow, from: nil)
        return items.first { $0.rect.contains(point) }?.kind
    }

    private func setHovered(_ kind: Kind?) {
        guard kind != hovered else { return }
        hovered = kind
        needsDisplay = true
        toolTip = kind.flatMap(tooltip(for:))
    }

    private func tooltip(for kind: Kind) -> String? {
        switch kind {
        case .chip: return "Switch workspace"
        case .tab(let i):
            guard case .link(let link) = model.entries[i] else { return nil }
            return "\(link.title)\n\(TablineGlyph.host(of: link.url))"
        case .group(let i):
            guard case .group(let folder, let links) = model.entries[i] else { return nil }
            return "\(folder.name) · \(links.count) sites"
        case .ghost: return model.ghost.map { "Stow this page\n\($0.host) → \(model.name)" }
        case .overflow: return "\(hiddenEntryIndices.count) more"
        case .pocket: return "Tasks & snippets in \(model.name)"
        }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(kind(at: event)) }
    override func mouseEntered(with event: NSEvent) { setHovered(kind(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    override func mouseDown(with event: NSEvent) {
        pressed = kind(at: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let target = pressed
        pressed = nil
        needsDisplay = true
        guard let target, target == kind(at: event), let rect = rect(of: target) else { return }
        onActivate?(target, rect)
        setHovered(nil)
    }
}

private extension TablineEntry {
    var isGroup: Bool { if case .group = self { return true } else { return false } }
}
