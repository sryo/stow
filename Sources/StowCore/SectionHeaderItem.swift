import AppKit

/// Labels that split the node list into parts: "TASKS · 2 open" in the sidebar, the
/// counted "Tasks" row at list width, and group labels over mosaic tiles.
final class SectionHeaderItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeaderItem")

    enum Style {
        /// Small-caps label with the count at the far end (sidebar and mosaic sections).
        case label
        /// List width: glyph, small-caps label and count, clickable to expand in place.
        case countedRow
        /// A folder's name over its tiles in the mosaic.
        case folderGroup
    }

    private let header = SectionHeaderView()
    override func loadView() { view = header }

    func configure(style: Style, title: String, meta: String, symbol: String?, isExpanded: Bool,
                   metrics: ListMetrics, horizontalInset: CGFloat) {
        view.alphaValue = 1
        header.configure(style: style, title: title, meta: meta, symbol: symbol, isExpanded: isExpanded,
                         metrics: metrics, horizontalInset: horizontalInset)
    }

    func setKeyboardFocused(_ focused: Bool) { header.isKeyboardFocused = focused }
}

private final class SectionHeaderView: BaseView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var style: SectionHeaderItem.Style = .label
    private var metrics = ListMetrics()
    private var inset: CGFloat = 0
    var isKeyboardFocused = false { didSet { paint() } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.alignment = .right
        metaLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        for v in [iconView, titleLabel, metaLabel] { addSubview(v) }
        layer?.cornerRadius = 7
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(style: SectionHeaderItem.Style, title: String, meta: String, symbol: String?, isExpanded: Bool,
                   metrics: ListMetrics, horizontalInset: CGFloat) {
        self.style = style
        self.metrics = metrics
        self.inset = horizontalInset
        if style == .folderGroup {
            titleLabel.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: metrics.folderTitleFont, .foregroundColor: metrics.titleColor,
            ])
        } else {
            // 10.5pt bold, uppercase, tracked 0.07em.
            titleLabel.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .kern: 0.735,
                .foregroundColor: metrics.secondaryColor,
            ])
        }
        metaLabel.stringValue = meta
        metaLabel.textColor = metrics.secondaryColor
        if let symbol {
            iconView.isHidden = false
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            iconView.contentTintColor = metrics.secondaryColor
        } else {
            iconView.isHidden = true
        }
        switch style {
        case .countedRow:
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(title), \(meta), \(isExpanded ? "expanded" : "collapsed")")
        default:
            setAccessibilityRole(.staticText)
            setAccessibilityLabel("\(title), \(meta)")
        }
        needsLayout = true
        paint()
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let textH: CGFloat = 16
        let ty = ((h - textH) / 2).rounded()
        switch style {
        case .label:
            let metaW: CGFloat = 70
            titleLabel.frame = NSRect(x: inset, y: ty, width: max(0, w - inset * 2 - metaW - 6), height: textH)
            metaLabel.frame = NSRect(x: w - inset - metaW, y: ty, width: metaW, height: textH)
        case .countedRow:
            let metaW: CGFloat = 56
            iconView.frame = NSRect(x: 7, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
            titleLabel.frame = NSRect(x: 30, y: ty, width: max(0, w - 30 - 8 - metaW - 6), height: textH)
            metaLabel.frame = NSRect(x: w - 8 - metaW, y: ty, width: metaW, height: textH)
        case .folderGroup:
            let metaW: CGFloat = 70
            iconView.frame = NSRect(x: 0, y: ((h - 14) / 2).rounded(), width: 14, height: 14)
            titleLabel.frame = NSRect(x: 20, y: ty, width: max(0, w - 20 - metaW - 4), height: textH)
            metaLabel.frame = NSRect(x: w - metaW, y: ty, width: metaW, height: textH)
        }
        // Text cells inset their text 2pt; widen the frames so the text lands on the grid.
        titleLabel.frame = titleLabel.frame.insetBy(dx: -2, dy: 0)
        metaLabel.frame = metaLabel.frame.insetBy(dx: -2, dy: 0)
    }

    override func handleHoverStateChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let hoverable = style == .countedRow
        layer?.backgroundColor = resolvedCGColor(hoverable && isHovered ? metrics.hoverBackgroundColor : .clear)
        layer?.borderWidth = isKeyboardFocused ? 2 : 0
        layer?.borderColor = resolvedCGColor(metrics.colors.accent)
    }
}
