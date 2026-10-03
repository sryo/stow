import AppKit

/// One workspace in the Settings list: a fixed 28pt row with the workspace icon, name,
/// browser profile chip, item count and a "…" menu button.
///
/// At rest the row is neutral on the Settings surface. Hovering or focusing it fills it
/// with that workspace's own page color in the current tint mode, so you see the page
/// before you swipe to it.
final class WorkspaceRowView: BaseView {
    struct Content {
        var name: String
        var colorId: WorkspaceColorId
        var iconLinks: [Link]
        var profileName: String?
        var itemCount: Int
        var position: Int
        var total: Int
        var canDelete: Bool
    }

    private let iconView = WorkspaceIconView()
    private let editableTitle = InlineEditableTextField()
    private let profileChip = ProfileChipButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = SettingsIconButton(symbolName: "ellipsis", accessibilityLabel: "Workspace menu", size: StowTheme.List.actionSlot + 2, pointSize: 11)
    private var content: Content?
    private var pagePalette: StowTheme.Colors?
    private(set) var isFocused = false

    var onShowMenu: ((NSView) -> Void)?
    var onShowColorMenu: ((NSView) -> Void)?
    var onShowProfileMenu: ((NSView) -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMove: ((WorkspaceMoveDirection) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        focusRingType = .none
        layer?.cornerRadius = SettingsMetrics.rowRadius

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.onClick = { [weak self] in
            guard let self else { return }
            self.onShowColorMenu?(self.iconView)
        }

        editableTitle.translatesAutoresizingMaskIntoConstraints = false
        editableTitle.font = StowTheme.Font.row
        editableTitle.textColor = SettingsColors.ink
        editableTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editableTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        profileChip.translatesAutoresizingMaskIntoConstraints = false
        profileChip.isHidden = true
        profileChip.target = self
        profileChip.action = #selector(profileChipClicked)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: StowTheme.Font.meta.pointSize, weight: .medium)
        countLabel.textColor = SettingsColors.inkSecondary
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setAccessibilityElement(false)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.target = self
        menuButton.action = #selector(menuButtonClicked)
        menuButton.alphaValue = 0

        addSubview(iconView)
        addSubview(editableTitle)
        addSubview(profileChip)
        addSubview(countLabel)
        addSubview(menuButton)

        let chipMaxWidth = profileChip.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.rowPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: StowTheme.List.glyphSize),
            iconView.heightAnchor.constraint(equalToConstant: StowTheme.List.glyphSize),

            editableTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: StowTheme.List.glyphToTitle),
            editableTitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            editableTitle.trailingAnchor.constraint(lessThanOrEqualTo: profileChip.leadingAnchor, constant: -6),
            editableTitle.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            profileChip.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),
            profileChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chipMaxWidth,

            countLabel.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(tintModeChanged), name: .stowTintModeChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(_ content: Content) {
        let colorChanged = self.content?.colorId != content.colorId
        self.content = content
        if colorChanged || pagePalette == nil {
            pagePalette = WorkspaceRowView.palette(for: content.colorId)
        }

        if !editableTitle.isEditing {
            editableTitle.text = content.name
        }
        editableTitle.textField.toolTip = content.name

        iconView.configure(name: content.name, colorId: content.colorId, links: content.iconLinks)

        if let profile = content.profileName {
            profileChip.title = profile
            profileChip.isHidden = false
        } else {
            profileChip.isHidden = true
        }
        countLabel.stringValue = "\(content.itemCount)"

        updateAccessibility()
        refreshHoverState()
        applyState()
    }

    // MARK: Palette

    private static var paletteCache: [String: StowTheme.Colors] = [:]

    /// The workspace's page palette in the current tint mode, cached per color and mode.
    static func palette(for colorId: WorkspaceColorId) -> StowTheme.Colors {
        let tint = StowTheme.preferredTint
        let key = "\(colorId.color.hexString)-\(tint.rawValue)"
        if let cached = paletteCache[key] { return cached }
        let colors = StowTheme.colors(for: colorId, tint: tint)
        paletteCache[key] = colors
        return colors
    }

    @objc private func tintModeChanged() {
        guard let content else { return }
        pagePalette = WorkspaceRowView.palette(for: content.colorId)
        applyState()
    }

    // MARK: State

    private var isActive: Bool { isHovered || isFocused || editableTitle.isEditing }

    override func handleHoverStateChanged() {
        applyState()
    }

    private func applyState() {
        needsDisplay = true
        let active = isActive
        let palette = active ? pagePalette : nil
        let ink = palette?.inkPrimary ?? SettingsColors.ink
        let secondary = palette?.inkSecondary ?? SettingsColors.inkSecondary
        if !editableTitle.isEditing {
            editableTitle.textColor = ink
        }
        countLabel.textColor = secondary
        profileChip.tint = secondary
        menuButton.tint = active ? ink : nil
        iconView.ringColor = palette?.inkSecondary ?? SettingsColors.edge
        menuButton.alphaValue = (active && !editableTitle.isEditing) ? 1 : 0
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let active = isActive && !editableTitle.isEditing
        layer?.backgroundColor = active ? (pagePalette?.hover ?? SettingsColors.fill).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 0
        layer?.borderColor = SettingsColors.accent.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        iconView.needsDisplay = true
    }

    // MARK: Rename

    var isInlineRenaming: Bool {
        editableTitle.isEditing
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        editableTitle.beginInlineRename(
            onCommit: { [weak self] name in
                onCommit(name)
                self?.applyState()
            },
            onCancel: { [weak self] in
                onCancel()
                self?.applyState()
            }
        )
        applyState()
    }

    func cancelInlineRename() {
        editableTitle.cancelInlineRename()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !editableTitle.isEditing {
            onRename?()
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onShowMenu?(menuButton)
    }

    @objc private func menuButtonClicked() {
        onShowMenu?(menuButton)
    }

    @objc private func profileChipClicked() {
        onShowProfileMenu?(profileChip)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        NSApp.currentEvent?.type != .leftMouseDown && NSApp.currentEvent?.type != .rightMouseDown
    }

    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        applyState()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        applyState()
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where flags.isEmpty, 76 where flags.isEmpty: // Return
            onRename?()
        case 36 where flags == .control:
            onShowMenu?(menuButton)
        case 49: // Space
            onShowMenu?(menuButton)
        case 109 where flags.contains(.shift): // ⇧F10
            onShowMenu?(menuButton)
        case 51 where flags.contains(.command), 117 where flags.contains(.command): // ⌘⌫
            if content?.canDelete == true { onDelete?() } else { NSSound.beep() }
        case 126 where flags.contains([.command, .option]): // ⌥⌘↑
            onMove?(.left)
        case 125 where flags.contains([.command, .option]): // ⌥⌘↓
            onMove?(.right)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        guard let content else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        var parts = [content.name, content.colorId.name, "\(content.position) of \(content.total)",
                     "\(content.itemCount) \(content.itemCount == 1 ? "item" : "items")"]
        if let profile = content.profileName { parts.append("profile \(profile)") }
        setAccessibilityLabel(parts.joined(separator: ", "))
        if !content.canDelete {
            setAccessibilityHelp("The only workspace can't be deleted.")
        } else {
            setAccessibilityHelp(nil)
        }
        var actions = [
            NSAccessibilityCustomAction(name: "Rename workspace") { [weak self] in self?.onRename?(); return true },
            NSAccessibilityCustomAction(name: "Change color") { [weak self] in
                guard let self else { return false }
                self.onShowColorMenu?(self.iconView); return true
            },
        ]
        if content.position > 1 {
            actions.append(NSAccessibilityCustomAction(name: "Move up") { [weak self] in self?.onMove?(.left); return true })
        }
        if content.position < content.total {
            actions.append(NSAccessibilityCustomAction(name: "Move down") { [weak self] in self?.onMove?(.right); return true })
        }
        if content.canDelete {
            actions.append(NSAccessibilityCustomAction(name: "Delete workspace") { [weak self] in self?.onDelete?(); return true })
        }
        setAccessibilityCustomActions(actions)
    }

    override func accessibilityPerformPress() -> Bool {
        onShowMenu?(menuButton)
        return true
    }
}

// MARK: - Workspace icon

/// The workspace's icon in a 16pt slot: a 2×2 mosaic of its most representative
/// favicons, or a dot in the workspace color with its first letter when it has none.
final class WorkspaceIconView: NSView {
    private var colorId: WorkspaceColorId = .defaultColor()
    private var letter = ""
    private var images: [NSImage] = []
    var onClick: (() -> Void)?
    var ringColor: NSColor = SettingsColors.edge {
        didSet { needsDisplay = true }
    }

    private static let imageCache = NSCache<NSString, NSImage>()

    override var isFlipped: Bool { true }

    func configure(name: String, colorId: WorkspaceColorId, links: [Link]) {
        self.colorId = colorId
        letter = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? ""
        images = links.compactMap { link in
            guard let path = link.faviconPath else { return nil }
            if let cached = Self.imageCache.object(forKey: path as NSString) { return cached }
            guard let image = NSImage(contentsOfFile: path) else { return nil }
            Self.imageCache.setObject(image, forKey: path as NSString)
            return image
        }
        setAccessibilityElement(false)
        toolTip = "Change color"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        if images.isEmpty {
            let dot = NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)
            let path = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            colorId.color.setFill()
            path.fill()
            ringColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            guard !letter.isEmpty else { return }
            let ink = StowTheme.colors(for: colorId, tint: .full).light.inkPrimary.platformColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: ink,
            ]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: NSPoint(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2), withAttributes: attributes)
            return
        }
        if images.count == 1 {
            draw(images[0], in: rect.insetBy(dx: 1, dy: 1), radius: 3)
            return
        }
        let gap: CGFloat = 1
        let cell = (rect.width - gap) / 2
        for index in 0..<4 {
            let frame = NSRect(x: rect.minX + CGFloat(index % 2) * (cell + gap),
                               y: rect.minY + CGFloat(index / 2) * (cell + gap),
                               width: cell, height: cell)
            if index < images.count {
                draw(images[index], in: frame, radius: 1.5)
            } else {
                let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 1.5, yRadius: 1.5)
                colorId.color.setFill()
                path.fill()
            }
        }
    }

    private func draw(_ image: NSImage, in frame: NSRect, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Profile chip

/// "􀉩 Work": the workspace's browser profile in Font.meta. Clicking it opens the
/// Browser profile submenu.
private final class ProfileChipButton: BaseControl {
    private let symbolView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet {
            label.stringValue = title
            label.toolTip = title
            setAccessibilityLabel("Browser profile, \(title)")
        }
    }

    var tint: NSColor = SettingsColors.inkSecondary {
        didSet {
            label.textColor = tint
            symbolView.contentTintColor = tint
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.meta
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(symbolView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        tint = SettingsColors.inkSecondary
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
