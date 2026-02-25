import AppKit

/// A tile view representing a single pinned link with its favicon.
@MainActor
final class PinnedTabTileView: BaseControl {
    let linkId: UUID
    private let imageView = NSImageView()
    private let globeIconConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

    var onClick: ((UUID) -> Void)?
    var onRightClick: ((UUID, NSPoint) -> Void)?

    init(link: Link) {
        self.linkId = link.id
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = ThemeConstants.CornerRadius.medium

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconLarge),
            imageView.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconLarge),
        ])

        updateFavicon(link: link)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFavicon(link: Link) {
        if let path = link.faviconPath,
           FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path) {
            image.isTemplate = false
            imageView.image = image
        } else {
            let placeholder = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(globeIconConfig)
            placeholder?.isTemplate = true
            imageView.image = placeholder
            imageView.contentTintColor = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.medium)
        }
    }

    override func handleHoverStateChanged() {
        layer?.backgroundColor = isHovered
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
            : NSColor.clear.cgColor
    }

    override func handlePressedStateChanged() {
        layer?.backgroundColor = isPressed
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.subtle).cgColor
            : (isHovered ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor : NSColor.clear.cgColor)
    }

    override func performAction() {
        onClick?(linkId)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightClick?(linkId, convert(point, to: window?.contentView))
    }
}
