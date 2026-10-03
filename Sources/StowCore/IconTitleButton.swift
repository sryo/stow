import AppKit

final class IconTitleButton: BaseControl {
    struct Style {
        var backgroundColor: NSColor
        var hoverBackgroundOpacity: CGFloat
        var pressedBackgroundOpacity: CGFloat
        var foregroundColor: NSColor
        var foregroundInactiveOpacity: CGFloat
        var foregroundActiveOpacity: CGFloat
        var font: NSFont
        var iconPointSize: CGFloat
        var iconWeight: NSFont.Weight
        var iconTitleSpacing: CGFloat
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var cornerRadius: CGFloat
        var fillsWidth: Bool

        static var pasteAction: Style {
            Style(
                backgroundColor: ThemeConstants.Colors.darkGray,
                hoverBackgroundOpacity: ThemeConstants.Opacity.minimal,
                pressedBackgroundOpacity: ThemeConstants.Opacity.extraSubtle,
                foregroundColor: ThemeConstants.Colors.darkGray,
                foregroundInactiveOpacity: ThemeConstants.Opacity.high,
                foregroundActiveOpacity: ThemeConstants.Opacity.full,
                font: StowTheme.Font.control,
                iconPointSize: 13,
                iconWeight: .medium,
                iconTitleSpacing: StowTheme.List.glyphToTitle,
                horizontalPadding: StowTheme.List.horizontalInset + 2,
                verticalPadding: 8,
                cornerRadius: StowTheme.List.rowRadius,
                fillsWidth: true
            )
        }

        /// Compact bottom-bar button that hugs its title.
        static var toolbar: Style {
            var style = pasteAction
            style.fillsWidth = false
            style.horizontalPadding = 8
            return style
        }

        static var addWorkspace: Style {
            Style(
                backgroundColor: ThemeConstants.Colors.darkGray,
                hoverBackgroundOpacity: ThemeConstants.Opacity.minimal,
                pressedBackgroundOpacity: ThemeConstants.Opacity.extraSubtle,
                foregroundColor: ThemeConstants.Colors.darkGray,
                foregroundInactiveOpacity: ThemeConstants.Opacity.high,
                foregroundActiveOpacity: ThemeConstants.Opacity.full,
                font: ThemeConstants.Fonts.bodySemibold,
                iconPointSize: ThemeConstants.Sizing.iconSmall,
                iconWeight: .medium,
                iconTitleSpacing: ThemeConstants.Spacing.small,
                horizontalPadding: ThemeConstants.Spacing.regular,
                verticalPadding: ThemeConstants.Spacing.regular,
                cornerRadius: ThemeConstants.CornerRadius.medium,
                fillsWidth: false
            )
        }

        var height: CGFloat {
            let textHeight = ceil(font.ascender - font.descender)
            let contentHeight = max(iconPointSize, textHeight)
            return contentHeight + (verticalPadding * 2)
        }
    }

    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var titleTrailingConstraint: NSLayoutConstraint?

    var style: Style {
        didSet {
            applyStyle()
        }
    }

    var symbolName: String {
        didSet {
            updateIcon()
        }
    }

    /// When set, colors come from the workspace palette instead of the style.
    var colors: StowTheme.Colors? {
        didSet { updateAppearance() }
    }

    private let hintLabel = NSTextField(labelWithString: "")

    /// A keycap shown after the title, e.g. while ⌘ is held. Nil hides it.
    var shortcutHint: String? {
        didSet {
            hintLabel.stringValue = shortcutHint ?? ""
            hintLabel.isHidden = shortcutHint == nil
            titleTrailingConstraint?.constant = -style.horizontalPadding - (shortcutHint == nil ? 0 : hintLabel.intrinsicContentSize.width + 6)
            invalidateIntrinsicContentSize()
        }
    }

    var titleText: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    init(title: String, symbolName: String, style: Style) {
        self.style = style
        self.symbolName = symbolName
        super.init(frame: .zero)
        titleField.stringValue = title
        setupView()
        updateIcon()
        applyStyle()
    }

    required init?(coder: NSCoder) {
        self.style = .pasteAction
        self.symbolName = "plus"
        super.init(coder: coder)
        setupView()
        updateIcon()
        applyStyle()
    }

    private func setupView() {
        layer?.masksToBounds = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleField.stringValue)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .left

        addSubview(imageView)
        addSubview(titleField)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = StowTheme.Font.keycap
        hintLabel.isHidden = true
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 6),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        iconLeadingConstraint = imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.horizontalPadding)
        iconWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: style.iconPointSize)
        iconHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: style.iconPointSize)
        titleLeadingConstraint = titleField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: style.iconTitleSpacing)
        titleTrailingConstraint = titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.horizontalPadding)

        NSLayoutConstraint.activate([
            iconLeadingConstraint!,
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint!,
            iconHeightConstraint!,
            titleLeadingConstraint!,
            titleTrailingConstraint!,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if style.fillsWidth {
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            // Hugs its title, but may truncate so narrow (rail) windows aren't blocked.
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.required, for: .horizontal)
        }
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateIcon() {
        let config = NSImage.SymbolConfiguration(pointSize: style.iconPointSize, weight: style.iconWeight)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        imageView.image?.isTemplate = true
    }

    private func applyStyle() {
        layer?.cornerRadius = style.cornerRadius
        titleField.font = style.font

        iconLeadingConstraint?.constant = style.horizontalPadding
        titleLeadingConstraint?.constant = style.iconTitleSpacing
        titleTrailingConstraint?.constant = -style.horizontalPadding
        iconWidthConstraint?.constant = style.iconPointSize
        iconHeightConstraint?.constant = style.iconPointSize

        updateIcon()
        updateAppearance()
    }

    override func handleHoverStateChanged() {
        updateAppearance()
    }

    override func handlePressedStateChanged() {
        updateAppearance()
    }

    /// Sets text/icon color during swipe based on overlap fraction (0 = default, 1 = fully selected).
    /// Pass nil to restore default appearance.
    func setSwipeTextColor(_ fraction: CGFloat?, selectedColor: NSColor) {
        guard let fraction else {
            let foregroundColor = style.foregroundColor.withAlphaComponent(style.foregroundInactiveOpacity)
            titleField.textColor = foregroundColor
            imageView.contentTintColor = foregroundColor
            return
        }
        let from = style.foregroundColor.withAlphaComponent(style.foregroundInactiveOpacity)
        if let blended = from.blended(withFraction: fraction, of: selectedColor) {
            titleField.textColor = blended
            imageView.contentTintColor = blended
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        if let colors {
            let fill: NSColor = isPressed ? colors.multiSelected : (isHovered ? colors.hover : .clear)
            layer?.backgroundColor = resolvedCGColor(fill)
            titleField.textColor = colors.inkPrimary
            imageView.contentTintColor = colors.inkPrimary
            hintLabel.textColor = colors.inkSecondary
            return
        }
        let backgroundOpacity: CGFloat
        if isPressed {
            backgroundOpacity = style.pressedBackgroundOpacity
        } else if isHovered {
            backgroundOpacity = style.hoverBackgroundOpacity
        } else {
            backgroundOpacity = 0
        }

        if backgroundOpacity > 0 {
            layer?.backgroundColor = style.backgroundColor.withAlphaComponent(backgroundOpacity).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        let foregroundOpacity = (isPressed || isHovered) ? style.foregroundActiveOpacity : style.foregroundInactiveOpacity
        let foregroundColor = style.foregroundColor.withAlphaComponent(foregroundOpacity)
        titleField.textColor = foregroundColor
        imageView.contentTintColor = foregroundColor
    }
}
