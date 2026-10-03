import AppKit

/// Shared metrics for the Settings page. Rows match the node list (28pt, radius 6), and
/// every label or glyph sits 6pt inside its row.
@MainActor
enum SettingsMetrics {
    static let rowHeight: CGFloat = StowTheme.List.rowHeight(.compact)
    static let rowRadius: CGFloat = StowTheme.List.rowRadius
    static let rowPadding: CGFloat = 6
    static let controlHeight: CGFloat = 22
    static let headerHeight: CGFloat = 20
    static let helpLineHeight: CGFloat = 16
    static let groupGap: CGFloat = 12
    static let focusRingWidth: CGFloat = 2
}

// MARK: - Focus

/// A BaseControl that can take keyboard focus with Tab, draws an accent ring while
/// focused, and performs its action on Space or Return.
@MainActor
class FocusableControl: BaseControl {
    private(set) var isFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    /// Clicks don't move focus (as with system buttons); Tab does.
    override var acceptsFirstResponder: Bool {
        guard isEnabled else { return false }
        return NSApp.currentEvent?.type != .leftMouseDown
    }

    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        focusStateChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        focusStateChanged()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: // Space, Return, keypad Enter
            performAction()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performAction()
        return true
    }

    /// Subclasses refresh their look; the default redraws the layer.
    func focusStateChanged() {
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Section header

/// "Workspaces", "Appearance"…: 20pt tall, Font.section in inkSecondary, read as a heading.
final class SettingsSectionHeader: NSView {
    private let label: NSTextField

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.section
        label.textColor = SettingsColors.inkSecondary
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.headerHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.rowPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Labels

@MainActor
enum SettingsLabel {
    /// A 13pt row label that truncates with a tail ellipsis and shows its full text as a tooltip.
    static func row(_ text: String) -> NSTextField {
        let label = TruncatingLabel(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.row
        label.textColor = SettingsColors.ink
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    static func meta(_ text: String) -> NSTextField {
        let label = TruncatingLabel(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.meta
        label.textColor = SettingsColors.inkSecondary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// A label that sets its tooltip to the full text only while the text is truncated.
final class TruncatingLabel: NSTextField {
    override func layout() {
        super.layout()
        let fits = (cell?.cellSize.width ?? 0) <= bounds.width + 0.5
        toolTip = fits ? nil : stringValue
    }
}

// MARK: - Row

/// A 28pt settings row: a label on the left and a trailing control. When the row is too
/// narrow for both, the control wraps below the label and the row grows to 50pt.
final class SettingsRow: NSView {
    let label: NSTextField
    let control: NSView
    private let symbolView: NSImageView?
    private let isFullWidth: Bool
    private var inlineConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private(set) var isStacked = false

    static let stackedHeight: CGFloat = 50

    init(title: String, control: NSView, detail: String? = nil, symbolName: String? = nil) {
        label = SettingsLabel.row(title)
        self.control = control
        isFullWidth = false
        symbolView = symbolName.map { name in
            let view = NSImageView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            view.contentTintColor = SettingsColors.danger
            return view
        }
        super.init(frame: .zero)
        control.translatesAutoresizingMaskIntoConstraints = false
        // A segmented choice drops its previews before the label truncates.
        let compresses = control is SettingsSegmentedControl
        control.setContentCompressionResistancePriority(compresses ? NSLayoutConstraint.Priority(249) : .defaultHigh, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        addSubview(control)

        if let detail {
            let attributed = NSMutableAttributedString(string: title, attributes: [
                .font: StowTheme.Font.row, .foregroundColor: SettingsColors.ink,
            ])
            attributed.append(NSAttributedString(string: " · \(detail)", attributes: [
                .font: StowTheme.Font.meta, .foregroundColor: SettingsColors.inkSecondary,
            ]))
            label.attributedStringValue = attributed
        }

        let labelLeading: NSLayoutConstraint
        if let symbolView {
            addSubview(symbolView)
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
                symbolView.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
            labelLeading = label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 4)
        } else {
            labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding)
        }
        labelLeading.isActive = true

        let trailing = control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.rowPadding)
        trailing.priority = .defaultHigh
        trailing.isActive = true
        inlineConstraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        stackedConstraints = [
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.rowPadding),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ]
        NSLayoutConstraint.activate(inlineConstraints)
    }

    /// A row that holds only a control spanning its width (the Window mode choice).
    init(fullWidthControl control: NSView) {
        label = SettingsLabel.row("")
        self.control = control
        symbolView = nil
        isFullWidth = true
        super.init(frame: .zero)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        addSubview(control)
        let trailing = control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.rowPadding)
        trailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            trailing,
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Chooses inline or stacked for `width` and returns the row's height.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard !isFullWidth else { return SettingsMetrics.rowHeight }
        let controlWidth = (control as? SettingsSegmentedControl)?.compactWidth ?? control.fittingSize.width
        let labelWidth = min(ceil(label.cell?.cellSize.width ?? 0), 72) + (symbolView == nil ? 0 : 16)
        let stacked = width < SettingsMetrics.rowPadding * 2 + labelWidth + 8 + controlWidth
        if stacked != isStacked {
            isStacked = stacked
            NSLayoutConstraint.deactivate(stacked ? inlineConstraints : stackedConstraints)
            NSLayoutConstraint.activate(stacked ? stackedConstraints : inlineConstraints)
        }
        return stacked ? Self.stackedHeight : SettingsMetrics.rowHeight
    }
}

// MARK: - Status line

/// A 16pt help or status line under a row: an optional SF Symbol, the text, and optional
/// trailing pieces (a "Waiting" spinner, a dismiss button).
final class SettingsStatusLine: NSView {
    enum Kind { case help, success, danger }

    private let symbolView = NSImageView()
    private let label = SettingsLabel.meta("")
    private let trailingStack = NSStackView()
    private let dismissButton = SettingsIconButton(symbolName: "xmark", accessibilityLabel: "Dismiss", size: 16, pointSize: 8)
    private var labelLeadingToSymbol: NSLayoutConstraint!
    private var labelLeadingToEdge: NSLayoutConstraint!

    var onDismiss: (() -> Void)? {
        didSet { dismissButton.isHidden = onDismiss == nil }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        label.maximumNumberOfLines = 1
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isHidden = true
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)

        addSubview(symbolView)
        addSubview(label)
        addSubview(trailingStack)
        trailingStack.addArrangedSubview(dismissButton)

        labelLeadingToSymbol = label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 4)
        labelLeadingToEdge = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.helpLineHeight),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 12),
            symbolView.heightAnchor.constraint(equalToConstant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsMetrics.rowPadding),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        set(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Adds a view (such as a spinner) before the dismiss button.
    func addTrailing(_ view: NSView) {
        trailingStack.insertArrangedSubview(view, at: 0)
    }

    /// Sets the text, or hides the line when `text` is nil.
    func set(_ text: String?, kind: Kind = .help) {
        isHidden = text == nil
        label.stringValue = text ?? ""
        setAccessibilityElement(text != nil)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        label.setAccessibilityElement(false)
        let symbol: String?
        switch kind {
        case .help:
            symbol = nil
            label.textColor = SettingsColors.inkSecondary
        case .success:
            symbol = "checkmark.circle.fill"
            symbolView.contentTintColor = SettingsColors.success
            label.textColor = SettingsColors.ink
        case .danger:
            symbol = "exclamationmark.triangle.fill"
            symbolView.contentTintColor = SettingsColors.danger
            label.textColor = SettingsColors.ink
        }
        if let symbol {
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            symbolView.isHidden = false
            labelLeadingToEdge.isActive = false
            labelLeadingToSymbol.isActive = true
        } else {
            symbolView.isHidden = true
            labelLeadingToSymbol.isActive = false
            labelLeadingToEdge.isActive = true
        }
    }

    @objc private func dismiss() {
        onDismiss?()
    }
}

// MARK: - Buttons

/// A 22pt bordered button: Font.control on a raised fill with a controlEdge border.
final class SettingsButton: FocusableControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private var spinner: NSProgressIndicator?
    private var title: String
    private(set) var isLoading = false

    init(title: String, accessibilityLabel: String? = nil) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = StowTheme.Font.control
        titleLabel.textColor = SettingsColors.ink
        titleLabel.stringValue = title
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setAccessibilityElement(false)
        addSubview(titleLabel)
        layer?.cornerRadius = SettingsMetrics.rowRadius
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.controlHeight),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)
        titleLeading.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel ?? title)
    }

    private var titleLeading: NSLayoutConstraint!

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ newTitle: String) {
        title = newTitle
        titleLabel.stringValue = newTitle
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill: NSColor
        if isPressed && !isLoading {
            fill = SettingsColors.fillStrong
        } else if isHovered && isEnabled && !isLoading {
            fill = SettingsColors.fill
        } else {
            fill = SettingsColors.raised
        }
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = (isFocused ? SettingsColors.accent : SettingsColors.edge).cgColor
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 1
        titleLabel.textColor = (isEnabled && !isLoading) ? SettingsColors.ink : SettingsColors.inkSecondary
    }

    override func handleHoverStateChanged() { needsDisplay = true }
    override func handlePressedStateChanged() { needsDisplay = true }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func performAction() {
        guard !isLoading else { return }
        super.performAction()
    }

    /// Shows a small spinner before the title; the spinner follows the effective appearance.
    func setLoading(_ loading: Bool, title loadingTitle: String? = nil) {
        isLoading = loading
        if loading {
            if spinner == nil {
                let indicator = NSProgressIndicator()
                indicator.style = .spinning
                indicator.controlSize = .mini
                indicator.translatesAutoresizingMaskIntoConstraints = false
                addSubview(indicator)
                NSLayoutConstraint.activate([
                    indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                    indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
                    indicator.widthAnchor.constraint(equalToConstant: 12),
                    indicator.heightAnchor.constraint(equalToConstant: 12),
                ])
                spinner = indicator
            }
            spinner?.isHidden = false
            spinner?.startAnimation(nil)
            titleLeading.constant = 23
            if let loadingTitle { titleLabel.stringValue = loadingTitle }
        } else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
            titleLeading.constant = 9
            titleLabel.stringValue = title
        }
        needsDisplay = true
    }
}

/// A square icon button, borderless until hovered (the row "…" button), or bordered (Clear).
final class SettingsIconButton: FocusableControl {
    private let imageView = NSImageView()
    private let size: CGFloat
    var isBordered = false { didSet { needsDisplay = true } }
    /// Overrides the ink, e.g. with a hovered workspace row's palette.
    var tint: NSColor? { didSet { imageView.contentTintColor = tint ?? SettingsColors.inkSecondary } }

    init(symbolName: String, accessibilityLabel: String, size: CGFloat = SettingsMetrics.controlHeight, pointSize: CGFloat = 11) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        imageView.contentTintColor = SettingsColors.inkSecondary
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        layer?.cornerRadius = size <= 18 ? 4 : SettingsMetrics.rowRadius
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let ink = tint ?? SettingsColors.ink
        if isPressed {
            layer?.backgroundColor = ink.withAlphaComponent(0.14).cgColor
        } else if isHovered || isBordered {
            layer?.backgroundColor = (isBordered ? SettingsColors.raised : ink.withAlphaComponent(0.08)).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        if isFocused {
            layer?.borderWidth = SettingsMetrics.focusRingWidth
            layer?.borderColor = SettingsColors.accent.cgColor
        } else if isBordered {
            layer?.borderWidth = 1
            layer?.borderColor = SettingsColors.edge.cgColor
        } else {
            layer?.borderWidth = 0
        }
        imageView.contentTintColor = tint ?? (isHovered || isBordered ? SettingsColors.ink : SettingsColors.inkSecondary)
    }

    override func handleHoverStateChanged() { needsDisplay = true }
    override func handlePressedStateChanged() { needsDisplay = true }
}

/// A full-width 28pt text row such as "New workspace" or "Show 2 more": a leading
/// symbol and a label in inkSecondary, with a neutral hover fill.
final class SettingsActionRow: FocusableControl {
    private let symbolView = NSImageView()
    private let label = SettingsLabel.row("")

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        label.textColor = SettingsColors.inkSecondary
        label.setAccessibilityElement(false)
        symbolView.setAccessibilityElement(false)
        addSubview(symbolView)
        addSubview(label)
        layer?.cornerRadius = SettingsMetrics.rowRadius
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.rowHeight),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: StowTheme.List.glyphSize),
            symbolView.heightAnchor.constraint(equalToConstant: StowTheme.List.glyphSize),
            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: StowTheme.List.glyphToTitle),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.rowPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        configure(title: title, symbolName: symbolName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, symbolName: String) {
        label.stringValue = title
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        setAccessibilityLabel(title)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let active = isHovered || isFocused
        layer?.backgroundColor = (isPressed ? SettingsColors.fillStrong : active ? SettingsColors.fill : .clear).cgColor
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 0
        layer?.borderColor = SettingsColors.accent.cgColor
        let ink = active ? SettingsColors.ink : SettingsColors.inkSecondary
        label.textColor = ink
        symbolView.contentTintColor = ink
    }

    override func handleHoverStateChanged() { needsDisplay = true }
    override func handlePressedStateChanged() { needsDisplay = true }
}

// MARK: - Popup

/// A 22pt borderless popup on a raised, controlEdge-outlined field.
final class SettingsPopUp: NSView {
    let popup = NSPopUpButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.isBordered = false
        popup.font = StowTheme.Font.row
        popup.controlSize = .regular
        popup.contentTintColor = SettingsColors.ink
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        addSubview(popup)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.controlHeight),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsMetrics.rowRadius
        layer?.backgroundColor = SettingsColors.raised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SettingsColors.edge.cgColor
    }

    /// Re-applies the selected title in Font.row and ink.
    func refreshTitle() {
        guard let title = popup.titleOfSelectedItem else { return }
        popup.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: SettingsColors.ink,
            .font: StowTheme.Font.row,
        ])
    }
}
