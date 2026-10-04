import AppKit

/// A text button for the bottom bar ("+ Stow this tab ⌥⌘S", "Paste"), optionally
/// followed by an outlined keycap, styled like the mockup's `.fb`. As the list narrows it
/// drops the keycap, then shows only its symbol (`fit`).
final class FooterButton: BaseControl {
    /// How much of the button shows, roomiest first.
    enum Fit: Equatable { case full, noKeycap, icon }

    private let titleField = NSTextField(labelWithString: "")
    private let keycap = Keycap()
    private let symbolView = NSImageView()
    private var trailingToTitle: NSLayoutConstraint?
    private var trailingToKeycap: NSLayoutConstraint?
    private var trailingToSymbol: NSLayoutConstraint?

    var colors: StowTheme.Colors? { didSet { updateAppearance() } }

    /// Shown after the title; hidden when nil or when `fit` leaves it out.
    var keycapText: String? { didSet { updateKeycap() } }
    var fit: Fit = .full { didSet { if fit != oldValue { updateKeycap() } } }
    /// The SF Symbol `fit == .icon` shows in place of the title.
    let symbolName: String?

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue; setAccessibilityLabel(newValue); invalidateIntrinsicContentSize() }
    }

    /// The narrowest bar that still shows titles; below it the footer is icons only.
    static let titlesMinWidth: CGFloat = 164

    /// The roomiest fit for a bar `width` wide holding the stow button (`stowFull` with its
    /// keycap, `stowTitle` without) and Paste (`paste`), 4pt apart.
    static func footerFit(width: CGFloat, stowFull: CGFloat, stowTitle: CGFloat, paste: CGFloat) -> Fit {
        if width >= stowFull + 4 + paste { return .full }
        if width >= titlesMinWidth, width >= stowTitle + 4 + paste { return .noKeycap }
        return .icon
    }

    /// The button's width at `fit`, measured without changing what it shows.
    func fittingWidth(_ fit: Fit) -> CGFloat {
        switch fit {
        case .icon: return 8 + 14 + 8
        case .noKeycap: return 8 + ceil(titleField.attributedStringValue.size().width) + 4 + 8
        case .full:
            let title = fittingWidth(.noKeycap)
            guard keycapText != nil else { return title }
            return title + 4 + ceil(keycap.fittingSize.width)
        }
    }

    init(title: String, keycap keycapLabel: String? = nil, symbolName: String? = nil) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.lineBreakMode = .byClipping
        titleField.translatesAutoresizingMaskIntoConstraints = false
        keycap.translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        symbolView.isHidden = true
        symbolView.setAccessibilityElement(false)
        addSubview(titleField)
        addSubview(keycap)
        addSubview(symbolView)
        trailingToTitle = titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        trailingToKeycap = keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        trailingToSymbol = symbolView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            keycap.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        // Clip rather than hold the window open: Elastic narrows the panel to ~120pt.
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keycap.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.title = title
        self.keycapText = keycapLabel
        updateKeycap()
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateKeycap() {
        keycap.text = keycapText ?? ""
        let icon = fit == .icon && symbolView.image != nil
        let show = keycapText != nil && fit == .full
        keycap.isHidden = !show || icon
        titleField.isHidden = icon
        symbolView.isHidden = !icon
        trailingToKeycap?.isActive = false
        trailingToTitle?.isActive = false
        trailingToSymbol?.isActive = false
        (icon ? trailingToSymbol : show ? trailingToKeycap : trailingToTitle)?.isActive = true
        invalidateIntrinsicContentSize()
    }

    override func handleHoverStateChanged() { updateAppearance() }
    override func handlePressedStateChanged() { updateAppearance() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let c = colors ?? StowTheme.colors(for: .defaultColor())
        let fill: NSColor = isPressed ? c.multiSelected : (isHovered ? c.hover : .clear)
        layer?.backgroundColor = resolvedCGColor(fill)
        titleField.textColor = flattened(c.inkPrimary)
        symbolView.contentTintColor = flattened(c.inkPrimary)
        keycap.color = c.inkSecondary
    }

    private func flattened(_ color: NSColor) -> NSColor {
        var result = color
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }
}

/// A small outlined keycap: transparent fill, 1pt secondary-ink border, like `.search kbd`.
final class Keycap: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    var color: NSColor = .secondaryLabelColor { didSet { applyColor() } }
    var height: CGFloat = 16 { didSet { heightConstraint?.constant = height } }
    var fontSize: CGFloat = 9.5 { didSet { label.font = .systemFont(ofSize: fontSize, weight: .semibold) } }
    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        heightConstraint = heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightConstraint!,
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        var flat = color
        effectiveAppearance.performAsCurrentDrawingAppearance { flat = color.usingColorSpace(.sRGB) ?? color }
        label.textColor = flat
        layer?.borderColor = resolvedCGColor(color)
    }
}
