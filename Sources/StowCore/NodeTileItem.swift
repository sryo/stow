import AppKit

/// A mosaic tile (wide Elastic mode), laid out like the mockup's `mosL`:
/// links are 80pt cards (icon, name, domain), tasks are 38pt strips with the due date at
/// the end, and snippets are 80pt cards with the first two lines of code. Selection,
/// drag and menus come from the collection view, as for rows.
final class NodeTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NodeTileItem")
    private let tile = NodeTileView()

    override func loadView() { view = tile }

    func configure(content: NodeRowContent, metrics: ListMetrics, isSelected: Bool) {
        view.alphaValue = 1
        tile.configure(content: content, metrics: metrics, isSelected: isSelected)
    }

    func setKeyboardFocused(_ focused: Bool) { tile.isKeyboardFocused = focused }
}

private final class NodeTileView: BaseView {
    private enum Style { case link, task, snippet }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let badge = TileBadge()
    private let openDot = NSView()
    private var metrics = ListMetrics()
    private var isSelected = false
    private var style: Style = .link
    private var isOverdue = false
    private var isDone = false
    var isKeyboardFocused = false { didSet { paint() } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        metaLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail
        codeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeLabel.maximumNumberOfLines = 2
        codeLabel.lineBreakMode = .byClipping
        codeLabel.cell?.wraps = false
        codeLabel.cell?.truncatesLastVisibleLine = false
        openDot.wantsLayer = true
        openDot.layer?.cornerRadius = 2
        for v in [iconView, titleLabel, metaLabel, codeLabel, badge, openDot] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(content: NodeRowContent, metrics: ListMetrics, isSelected: Bool) {
        self.metrics = metrics
        self.isSelected = isSelected
        titleLabel.stringValue = content.title
        titleLabel.font = metrics.linkTitleFont
        var meta = ""
        isOverdue = false
        isDone = false
        badge.isHidden = true
        codeLabel.isHidden = true
        openDot.isHidden = true
        switch content.kind {
        case .folder(_, let count):
            style = .link
            setSymbol("folder", size: 15)
            meta = count == 1 ? "1 item" : "\(count) items"
        case .link(let favicon, let domain):
            style = .link
            if let favicon {
                favicon.isTemplate = false
                iconView.image = favicon
            } else {
                iconView.image = SiteGlyph.tileImage(title: content.title, host: domain ?? "", size: 26)
            }
            iconView.contentTintColor = nil
            meta = domain ?? ""
            openDot.isHidden = !content.isOpen
        case .task(let done, let due):
            style = .task
            isDone = done
            setSymbol(done ? "checkmark.circle.fill" : "circle", size: 13)
            if done {
                meta = "done"
            } else if let due {
                meta = NodeRowView.dueFormatter.string(from: due)
                if due < Calendar.current.startOfDay(for: Date()) { isOverdue = true; meta = "! " + meta }
            }
        case .snippet(let language):
            style = .snippet
            setSymbol("chevron.left.forwardslash.chevron.right", size: 12)
            if let language, !language.isEmpty {
                badge.isHidden = false
                badge.text = language
            }
            codeLabel.isHidden = false
            codeLabel.stringValue = Self.previewLines(content.codePreview ?? "")
        }
        metaLabel.stringValue = meta
        metaLabel.alignment = style == .link ? .left : .right
        if isDone {
            titleLabel.attributedStringValue = NSAttributedString(string: content.title, attributes: StowTheme.singleLineAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .font: metrics.linkTitleFont,
                .foregroundColor: metrics.secondaryColor,
            ]))
        }
        let open = content.isOpen && style == .link ? ", open in browser" : ""
        setAccessibilityLabel("\(content.typeName), \(content.title)\(meta.isEmpty ? "" : ", \(meta)")\(open)")
        layer?.cornerRadius = style == .task ? 10 : 12
        iconView.layer?.cornerRadius = style == .link ? 7 : 0
        needsLayout = true
        paint()
    }

    private static func previewLines(_ code: String) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n")
    }

    private func setSymbol(_ name: String, size: CGFloat) {
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        iconView.contentTintColor = metrics.iconTintColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        func line(_ field: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 16) {
            // Text cells inset their text 2pt; widen the frame so the text lands on x.
            field.frame = NSRect(x: x - 2, y: y, width: max(0, width + 4), height: height)
        }
        switch style {
        case .link:
            iconView.frame = NSRect(x: 11, y: 11, width: 26, height: 26)
            openDot.frame = NSRect(x: 5.5, y: 22, width: 4, height: 4)
            line(titleLabel, x: 11, y: 44, width: w - 22)
            line(metaLabel, x: 11, y: 60, width: w - 22, height: 15)
        case .task:
            iconView.frame = NSRect(x: 11, y: 11.5, width: 15, height: 15)
            line(metaLabel, x: w - 11 - 64, y: 11.5, width: 64, height: 15)
            line(titleLabel, x: 34, y: 10.5, width: w - 34 - 74)
        case .snippet:
            iconView.frame = NSRect(x: 11, y: 11, width: 16, height: 16)
            let badgeWidth = badge.isHidden ? 0 : min(60, ceil(badge.fittingSize.width))
            badge.frame = NSRect(x: w - 11 - badgeWidth, y: 11, width: badgeWidth, height: 15)
            line(titleLabel, x: 34, y: 10, width: w - 34 - 11 - (badgeWidth > 0 ? badgeWidth + 8 : 0))
            line(codeLabel, x: 11, y: 36, width: w - 22, height: 32)
        }
    }

    override func handleHoverStateChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let c = metrics.colors
        // The mockup's --s-tile: white at 58% over the page in light, 7.5% in dark.
        // Hover and selection darken (or lighten) it toward the ink, like --s-hover.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = isDark ? c.dark : c.light
        var tile = palette.surface.mix(.white, isDark ? 0.075 : 0.58)
        if isSelected || isHovered {
            tile = tile.mix(palette.inkPrimary, isSelected ? 0.12 : 0.065)
        }
        layer?.backgroundColor = tile.platformColor.cgColor
        layer?.borderWidth = isKeyboardFocused ? 2 : 0
        layer?.borderColor = resolvedCGColor(c.accent)
        if !isDone { titleLabel.textColor = c.inkPrimary }
        metaLabel.textColor = isOverdue ? c.overdue : c.inkSecondary
        codeLabel.textColor = c.inkSecondary
        badge.color = c.inkSecondary
        openDot.layer?.backgroundColor = resolvedCGColor(c.inkPrimary.withAlphaComponent(0.9))
    }
}

/// Outlined monospaced language tag, as on snippet rows.
private final class TileBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var color: NSColor = .secondaryLabelColor {
        didSet { label.textColor = color; needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.font = StowTheme.Font.badge
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = resolvedCGColor(color.withAlphaComponent(0.85)) }
}
