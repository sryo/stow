import AppKit

/// A mosaic tile (wide Elastic mode): icon, title and one line of metadata on a
/// rounded card. Selection, drag and menus come from the collection view, as for rows.
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
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var metrics = ListMetrics()
    private var isSelected = false
    var isKeyboardFocused = false { didSet { paint() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = StowTheme.Chrome.fieldRadius
        layer?.borderWidth = 1
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 5
        iconView.layer?.masksToBounds = true
        titleLabel.font = StowTheme.Font.rowEmphasized
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = false
        metaLabel.font = StowTheme.Font.meta
        metaLabel.lineBreakMode = .byTruncatingTail
        for v in [iconView, titleLabel, metaLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(content: NodeRowContent, metrics: ListMetrics, isSelected: Bool) {
        self.metrics = metrics
        self.isSelected = isSelected
        titleLabel.stringValue = content.title
        titleLabel.preferredMaxLayoutWidth = max(40, bounds.width - 20)
        var meta = ""
        switch content.kind {
        case .folder(_, let count):
            setSymbol("folder.fill")
            meta = count == 1 ? "1 item" : "\(count) items"
        case .link(let favicon, let domain):
            if let favicon { favicon.isTemplate = false; iconView.image = favicon; iconView.contentTintColor = nil } else { setSymbol("link") }
            meta = domain ?? ""
        case .task(let done, let due):
            setSymbol(done ? "checkmark.circle.fill" : "circle")
            if let due { meta = DateFormatter.localizedString(from: due, dateStyle: .medium, timeStyle: .none) }
        case .snippet(let language):
            setSymbol("chevron.left.forwardslash.chevron.right")
            meta = language ?? "Snippet"
        }
        metaLabel.stringValue = meta
        setAccessibilityLabel("\(content.typeName), \(content.title)\(meta.isEmpty ? "" : ", \(meta)")")
        paint()
    }

    private func setSymbol(_ name: String) {
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        iconView.contentTintColor = metrics.iconTintColor
    }

    override func handleHoverStateChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let c = metrics.colors
        let fill: NSColor = isSelected ? c.multiSelected : (isHovered ? c.hover : c.hover.withAlphaComponent(0.5))
        layer?.backgroundColor = resolvedCGColor(fill)
        layer?.borderWidth = isKeyboardFocused ? 2 : 1
        layer?.borderColor = resolvedCGColor(isKeyboardFocused ? c.accent : c.stroke)
        titleLabel.textColor = c.inkPrimary
        metaLabel.textColor = c.inkSecondary
    }
}
