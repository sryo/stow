import AppKit

/// A custom toggle switch control that matches Stow's design aesthetic
final class CustomToggle: BaseControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let switchContainer = NSView()
    private let switchThumb = NSView()
    private var thumbLeadingConstraint: NSLayoutConstraint?

    private let switchWidth: CGFloat = 32
    private let switchHeight: CGFloat = 18
    private let thumbSize: CGFloat = 14
    private let thumbInset: CGFloat = 2

    var isOn: Bool = false {
        didSet {
            if oldValue != isOn {
                updateAppearance(animated: true)
                sendAction(action, to: target)
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled {
                updateAppearance(animated: true)
            }
        }
    }

    var titleText: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(titleLabel.stringValue)
        titleLabel.setAccessibilityElement(false)

        // Title label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = StowTheme.Font.row
        titleLabel.textColor = SettingsColors.ink
        titleLabel.lineBreakMode = .byTruncatingTail

        // Switch container
        switchContainer.translatesAutoresizingMaskIntoConstraints = false
        switchContainer.wantsLayer = true
        switchContainer.layer?.cornerRadius = switchHeight / 2

        // Switch thumb
        switchThumb.translatesAutoresizingMaskIntoConstraints = false
        switchThumb.wantsLayer = true
        switchThumb.layer?.cornerRadius = thumbSize / 2

        addSubview(titleLabel)
        addSubview(switchContainer)
        switchContainer.addSubview(switchThumb)

        thumbLeadingConstraint = switchThumb.leadingAnchor.constraint(equalTo: switchContainer.leadingAnchor, constant: thumbInset)

        NSLayoutConstraint.activate([
            // Title label
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Switch container
            switchContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            switchContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            switchContainer.widthAnchor.constraint(equalToConstant: switchWidth),
            switchContainer.heightAnchor.constraint(equalToConstant: switchHeight),

            // Switch thumb
            thumbLeadingConstraint!,
            switchThumb.widthAnchor.constraint(equalToConstant: thumbSize),
            switchThumb.heightAnchor.constraint(equalToConstant: thumbSize),
            switchThumb.centerYAnchor.constraint(equalTo: switchContainer.centerYAnchor),
        ])

        updateAppearance(animated: false)
    }

    override func handleHoverStateChanged() {
        updateAppearance(animated: true)
    }

    override func handlePressedStateChanged() {
        updateAppearance(animated: !isPressed)
    }

    override func performAction() {
        isOn.toggle()
    }

    override var acceptsFirstResponder: Bool {
        isEnabled && NSApp.currentEvent?.type != .leftMouseDown
    }

    override var canBecomeKeyView: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { performAction() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performAction()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        // Switch background color
        let backgroundColor: NSColor
        if isOn {
            backgroundColor = SettingsColors.selection
        } else {
            backgroundColor = SettingsColors.fillStrong
        }

        let thumbColor = isOn ? SettingsColors.onSelection : SettingsColors.raised
        switchThumb.layer?.borderWidth = isOn ? 0 : 1
        switchThumb.layer?.borderColor = resolvedCGColor(SettingsColors.edge)

        // Position thumb
        let thumbLeadingOffset = isOn ? (switchWidth - thumbSize - thumbInset) : thumbInset

        // Opacity for disabled state
        let controlOpacity: CGFloat = isEnabled ? 1.0 : 0.5

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ThemeConstants.Animation.durationNormal
                context.timingFunction = ThemeConstants.Animation.timingFunction

                switchContainer.layer?.backgroundColor = resolvedCGColor(backgroundColor)
                switchThumb.layer?.backgroundColor = resolvedCGColor(thumbColor)
                switchContainer.alphaValue = controlOpacity
                titleLabel.alphaValue = controlOpacity

                thumbLeadingConstraint?.constant = thumbLeadingOffset
                switchContainer.layoutSubtreeIfNeeded()
            }
        } else {
            switchContainer.layer?.backgroundColor = resolvedCGColor(backgroundColor)
            switchThumb.layer?.backgroundColor = resolvedCGColor(thumbColor)
            switchContainer.alphaValue = controlOpacity
            titleLabel.alphaValue = controlOpacity
            thumbLeadingConstraint?.constant = thumbLeadingOffset
        }

        // The off track is outlined so it reads against the surface (fill alone is ~1.2:1).
        switchContainer.layer?.borderWidth = isOn ? 0 : 1
        switchContainer.layer?.borderColor = resolvedCGColor(SettingsColors.edge)

        setAccessibilityValue(isOn ? 1 : 0)
    }
}
