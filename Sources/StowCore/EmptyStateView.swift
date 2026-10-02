import AppKit

/// Centered glyph, headline and one sentence, drawn in the workspace palette.
final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    var colors: StowTheme.Colors? { didSet { applyColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [iconView, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(10, after: iconView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        titleLabel.font = StowTheme.Font.emptyTitle
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = StowTheme.Font.emptyBody
        messageLabel.alignment = .center
        messageLabel.isSelectable = false

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ copy: EmptyStateCopy) {
        iconView.image = NSImage(systemSymbolName: copy.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .light))
        titleLabel.stringValue = copy.title
        messageLabel.stringValue = copy.message
        setAccessibilityLabel("\(copy.title). \(copy.message)")
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        guard let colors else { return }
        iconView.contentTintColor = colors.inkSecondary
        titleLabel.textColor = colors.inkPrimary
        messageLabel.textColor = colors.inkSecondary
    }
}
