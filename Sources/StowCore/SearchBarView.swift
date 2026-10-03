import AppKit

final class SearchBarView: NSView, NSTextFieldDelegate {
    struct Style {
        var baseColor: NSColor
        var backgroundOpacity: CGFloat
        var placeholderOpacity: CGFloat
        var textOpacity: CGFloat
        var iconOpacity: CGFloat
        var font: NSFont
        var iconPointSize: CGFloat
        var iconWeight: NSFont.Weight
        var clearIconPointSize: CGFloat
        var clearIconWeight: NSFont.Weight
        var iconTitleSpacing: CGFloat
        var clearSpacing: CGFloat
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var cornerRadius: CGFloat

        static var defaultSearch: Style {
            Style(
                baseColor: ThemeConstants.Colors.darkGray,
                backgroundOpacity: ThemeConstants.Opacity.extraSubtle,
                placeholderOpacity: ThemeConstants.Opacity.medium,
                textOpacity: ThemeConstants.Opacity.full,
                iconOpacity: ThemeConstants.Opacity.high,
                font: StowTheme.Font.field,
                iconPointSize: 13,
                iconWeight: .medium,
                clearIconPointSize: 10,
                clearIconWeight: .bold,
                iconTitleSpacing: StowTheme.List.glyphToTitle,
                clearSpacing: 6,
                horizontalPadding: StowTheme.List.horizontalInset + 2,
                verticalPadding: 6,
                cornerRadius: StowTheme.Chrome.fieldRadius
            )
        }

        var height: CGFloat {
            let textHeight = ceil(font.ascender - font.descender)
            let contentHeight = max(iconPointSize, textHeight)
            return contentHeight + (verticalPadding * 2)
        }
    }

    private let iconView = NSImageView()
    private let textField = NSTextField(string: "")
    private let clearButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    /// "/" focuses search from the list; while ⌘ is held it reads "⌘F".
    private let shortcutLabel = Keycap()
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var clearTrailingConstraint: NSLayoutConstraint?
    private var clearWidthConstraint: NSLayoutConstraint?
    private var clearHeightConstraint: NSLayoutConstraint?
    private var textLeadingConstraint: NSLayoutConstraint?
    private var textTrailingConstraint: NSLayoutConstraint?

    var style: Style {
        didSet {
            applyStyle()
        }
    }

    var placeholder: String = "" {
        didSet { updatePlaceholder() }
    }

    var text: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            updateClearButtonVisibility()
        }
    }

    var onTextChange: ((String) -> Void)?
    /// Down arrow in the field, used to move focus into the results.
    var onMoveDown: (() -> Void)?

    /// When set, colors come from the workspace palette instead of the style.
    var colors: StowTheme.Colors? {
        didSet { applyStyle() }
    }

    /// Result count shown while filtering, e.g. "4 of 37". Nil hides it.
    var resultSummary: String? {
        didSet {
            countLabel.stringValue = resultSummary ?? ""
            countLabel.isHidden = resultSummary == nil
        }
    }

    /// Forces the keycap visible as ⌘F, e.g. while ⌘ is held.
    var showsShortcutHint = false {
        didSet {
            shortcutLabel.text = showsShortcutHint ? "⌘F" : "/"
            updateFocusRing()
        }
    }

    var isFocused: Bool {
        guard let editor = textField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    private var firstResponderObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        firstResponderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateFocusRing() }
        }
    }

    func focus() {
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
        updateFocusRing()
    }

    init(style: Style = .defaultSearch) {
        self.style = style
        super.init(frame: .zero)
        setupView()
        applyStyle()
    }

    required init?(coder: NSCoder) {
        self.style = .defaultSearch
        super.init(coder: coder)
        setupView()
        applyStyle()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: style.height)
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.delegate = self

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isBordered = false
        clearButton.title = ""
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        clearButton.setAccessibilityLabel("Clear search")
        textField.setAccessibilityLabel("Search")

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = StowTheme.Font.meta
        countLabel.isHidden = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.text = "/"
        shortcutLabel.height = 17
        shortcutLabel.fontSize = 10
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(textField)
        addSubview(clearButton)
        addSubview(countLabel)
        addSubview(shortcutLabel)

        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.horizontalPadding)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: style.iconPointSize)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: style.iconPointSize)
        clearTrailingConstraint = clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.horizontalPadding)
        clearWidthConstraint = clearButton.widthAnchor.constraint(equalToConstant: max(style.clearIconPointSize, 16))
        clearHeightConstraint = clearButton.heightAnchor.constraint(equalToConstant: max(style.clearIconPointSize, 16))
        textLeadingConstraint = textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: style.iconTitleSpacing)
        textTrailingConstraint = textField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -style.clearSpacing)

        NSLayoutConstraint.activate([
            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint!,
            iconHeightConstraint!,

            clearTrailingConstraint!,
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearWidthConstraint!,
            clearHeightConstraint!,

            textLeadingConstraint!,
            textTrailingConstraint!,
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.horizontalPadding),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // Text field cells resolve dynamic colors against the drawing appearance, which isn't
    // always the view's, so these are flattened to the view's appearance up front.
    private var ink: NSColor { flattened(colors?.inkPrimary ?? style.baseColor.withAlphaComponent(style.textOpacity)) }
    private var secondaryInk: NSColor { flattened(colors?.inkSecondary ?? style.baseColor.withAlphaComponent(style.placeholderOpacity)) }

    private func flattened(_ color: NSColor) -> NSColor {
        var result = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func updateFocusRing() {
        let focused = isFocused
        layer?.borderWidth = focused ? 2 : 0
        layer?.borderColor = resolvedCGColor(colors?.accent ?? .controlAccentColor)
        shortcutLabel.isHidden = !showsShortcutHint && (focused || !textField.stringValue.isEmpty)
    }

    private func applyStyle() {
        layer?.cornerRadius = style.cornerRadius
        if let colors {
            layer?.backgroundColor = resolvedCGColor(colors.hover)
        } else {
            layer?.backgroundColor = style.baseColor.withAlphaComponent(style.backgroundOpacity).cgColor
        }
        countLabel.textColor = secondaryInk
        shortcutLabel.color = colors?.inkSecondary ?? secondaryInk
        updateFocusRing()

        iconLeadingConstraint?.constant = style.horizontalPadding
        iconWidthConstraint?.constant = style.iconPointSize
        iconHeightConstraint?.constant = style.iconPointSize
        clearTrailingConstraint?.constant = -style.horizontalPadding
        let clearSize = max(style.clearIconPointSize, 16)
        clearWidthConstraint?.constant = clearSize
        clearHeightConstraint?.constant = clearSize
        textLeadingConstraint?.constant = style.iconTitleSpacing
        textTrailingConstraint?.constant = -style.clearSpacing

        iconView.image = symbolImage(name: "magnifyingglass", pointSize: style.iconPointSize, weight: style.iconWeight)
        iconView.contentTintColor = secondaryInk

        clearButton.image = symbolImage(name: "xmark", pointSize: style.clearIconPointSize, weight: style.clearIconWeight)
        clearButton.contentTintColor = secondaryInk

        textField.font = style.font
        textField.textColor = ink
        updatePlaceholder()
        updateClearButtonVisibility()
        invalidateIntrinsicContentSize()
    }

    private func updatePlaceholder() {
        guard !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: secondaryInk,
            .font: style.font
        ]
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: attributes)
    }

    private func updateClearButtonVisibility() {
        clearButton.isHidden = textField.stringValue.isEmpty
        updateFocusRing()
    }

    private func symbolImage(name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    @objc private func clearTapped() {
        textField.stringValue = ""
        updateClearButtonVisibility()
        onTextChange?("")
        window?.makeFirstResponder(textField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)), let onMoveDown {
            onMoveDown()
            return true
        }
        return false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        updateFocusRing()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        updateFocusRing()
    }

    func controlTextDidChange(_ obj: Notification) {
        updateClearButtonVisibility()
        onTextChange?(textField.stringValue)
    }
}
