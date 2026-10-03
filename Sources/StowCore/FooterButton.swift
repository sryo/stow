import AppKit

/// A text button for the bottom bar ("+ Stow this tab ⌥⌘S", "Paste"), optionally
/// followed by an outlined keycap, styled like the mockup's `.fb`.
final class FooterButton: BaseControl {
    private let titleField = NSTextField(labelWithString: "")
    private let keycap = Keycap()
    private var trailingToTitle: NSLayoutConstraint?
    private var trailingToKeycap: NSLayoutConstraint?

    var colors: StowTheme.Colors? { didSet { updateAppearance() } }

    /// Shown after the title; hidden when nil or when `showsKeycap` is off.
    var keycapText: String? { didSet { updateKeycap() } }
    var showsKeycap = true { didSet { updateKeycap() } }

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue; setAccessibilityLabel(newValue); invalidateIntrinsicContentSize() }
    }

    init(title: String, keycap keycapLabel: String? = nil) {
        super.init(frame: .zero)
        layer?.cornerRadius = 7
        setAccessibilityRole(.button)
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.lineBreakMode = .byClipping
        titleField.translatesAutoresizingMaskIntoConstraints = false
        keycap.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        addSubview(keycap)
        trailingToTitle = titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        trailingToKeycap = keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([
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
        let show = keycapText != nil && showsKeycap
        keycap.isHidden = !show
        trailingToKeycap?.isActive = false
        trailingToTitle?.isActive = false
        (show ? trailingToKeycap : trailingToTitle)?.isActive = true
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
