import AppKit

/// The 276pt workspace editor (as wide as the app sheet): name, color, icon, "Opens in",
/// then Open, Share…, Export… and a trash button that deletes at once, with an undo toast. Every change is reported at
/// once, so the workspace behind it updates as you edit. A new workspace, not created
/// yet, shows only Create.
@MainActor
final class WorkspaceEditorView: RailFlippedView, NSTextFieldDelegate {
    struct Content {
        var id: UUID
        var name: String
        var colorId: WorkspaceColorId
        var icon: WorkspaceIcon
        /// What each icon style would show, for the previews and the big tile.
        var favicons: WorkspaceTileIdentity
        var letter: WorkspaceTileIdentity
        var current: WorkspaceTileIdentity
        var itemCount: Int
        var position: Int
        /// "Chrome · Work" with its icon, or "Browser I'm using".
        var opensIn: OpensInMenu.Display
        /// Shown muted after "Browser I'm using": the browser it picks right now.
        var opensInNow: String?
        var canDelete: Bool
        /// Not created yet: committing creates it.
        var isNew = false
    }

    static let width: CGFloat = 276

    var onRename: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onColor: ((WorkspaceColorId) -> Void)?
    var onCustomColor: (() -> Void)?
    var onIcon: ((WorkspaceIcon) -> Void)?
    var opensInMenu: (() -> NSMenu?)?
    var onOpen: (() -> Void)?
    var onShare: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private(set) var content: Content?

    private let bigTile = WorkspaceTileView()
    let nameField = FlyoutNameField()
    private let meta = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let colorLabel = FlyoutLabel.section("Color")
    private var swatches: [SwatchButton] = []
    private let iconLabel = FlyoutLabel.section("Icon")
    private var iconChoices: [IconChoiceButton] = []
    private var symbolButtons: [SymbolButton] = []
    private let profileLabel = FlyoutLabel.section("Opens in")
    private let profileScope = FlyoutLabel.text("this Mac", size: 11, color: FlyoutColors.inkSecondary)
    private let profileRow = FlyoutPopRow(symbol: nil, accessibilityLabel: "Opens in")
    private let profileHint = FlyoutLabel.wrapping("", size: 11)
    private let footerLine = NSView()
    private let openButton = FlyoutButton("Open ↩", style: .primary)
    private let shareButton = FlyoutButton("Share…")
    private let exportButton = FlyoutButton("Export…")
    private let deleteButton = FlyoutButton(symbol: "trash", title: "Delete", style: .danger)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 372))
        bigTile.setAccessibilityElement(false)
        addSubview(bigTile)
        nameField.placeholderAttributedString = NSAttributedString(string: "Workspace name", attributes: [
            .font: FlyoutFonts.ui(14, .semibold), .foregroundColor: FlyoutColors.inkSecondary,
        ])
        nameField.setAccessibilityLabel("Workspace name")
        nameField.delegate = self
        addSubview(nameField)
        addSubview(meta)
        addSubview(colorLabel)
        for colorId in WorkspaceColorId.allCases {
            let swatch = SwatchButton(colorId: colorId)
            swatch.target = self
            swatch.action = #selector(swatchTapped(_:))
            swatches.append(swatch)
            addSubview(swatch)
        }
        let custom = SwatchButton(colorId: nil)
        custom.target = self
        custom.action = #selector(customTapped)
        swatches.append(custom)
        addSubview(custom)

        addSubview(iconLabel)
        for (style, title) in [(WorkspaceIcon.favicons, "Favicons"), (.letter, "Letter"), (.symbol("star"), "Symbol")] {
            let choice = IconChoiceButton(style: style, title: title)
            choice.target = self
            choice.action = #selector(iconTapped(_:))
            iconChoices.append(choice)
            addSubview(choice)
        }
        for name in WorkspaceTileIdentity.symbols {
            let button = SymbolButton(symbol: name)
            button.target = self
            button.action = #selector(symbolTapped(_:))
            symbolButtons.append(button)
            addSubview(button)
        }
        addSubview(profileLabel)
        profileScope.alignment = .right
        profileScope.toolTip = "Stored on this Mac only: browser profiles exist on one Mac."
        addSubview(profileScope)
        profileRow.menuProvider = { [weak self] in self?.opensInMenu?() }
        addSubview(profileRow)
        addSubview(profileHint)
        footerLine.wantsLayer = true
        addSubview(footerLine)
        openButton.target = self
        openButton.action = #selector(openTapped)
        addSubview(openButton)
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        addSubview(shareButton)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.toolTip = "Save this workspace as a .stow file"
        addSubview(exportButton)
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.toolTip = "Delete: deletes now; Undo brings it back"
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Content

    func configure(_ content: Content) {
        let previous = self.content
        self.content = content
        bigTile.colorId = content.colorId
        bigTile.identity = content.current
        // Keep the user's typing; only a different workspace (or an outside rename) resets it.
        if previous?.id != content.id || !nameField.isFocused {
            nameField.stringValue = content.name
        }
        nameField.ringColor = content.colorId.color.blended(withFraction: 0.3, of: FlyoutColors.ink) ?? FlyoutColors.ink
        meta.stringValue = "\(content.itemCount) \(content.itemCount == 1 ? "item" : "items")" + (WorkspaceShortcut.label(position: content.position).map { " · " + $0 } ?? "")
        for swatch in swatches {
            if let id = swatch.colorId { swatch.isOn = id == content.colorId } else if case .custom = content.colorId { swatch.isOn = true } else { swatch.isOn = false }
        }
        let symbol: String
        if case .symbol(let name) = content.icon { symbol = name } else { symbol = "star" }
        for choice in iconChoices {
            switch choice.style {
            case .favicons: choice.preview = content.favicons; choice.isOn = content.icon == .favicons
            case .letter: choice.preview = content.letter; choice.isOn = content.icon == .letter
            case .symbol: choice.preview = .symbol(symbol); if case .symbol = content.icon { choice.isOn = true } else { choice.isOn = false }
            }
            choice.colorId = content.colorId
        }
        for button in symbolButtons { button.isOn = button.symbol == symbol }
        profileRow.set(title: content.opensIn.title, detail: content.opensInNow.map { "\($0) now" }, icon: content.opensIn.icon)
        profileHint.stringValue = Self.opensInHint(content)
        deleteButton.isEnabled = content.canDelete
        openButton.title = content.isNew ? "Create ↩" : "Open ↩"
        for button in [shareButton, exportButton, deleteButton] { button.isHidden = content.isNew }
        deleteButton.toolTip = content.canDelete ? "Delete: deletes now; Undo brings it back" : "The only workspace can't be deleted"
        let symbolsShown = { (c: Content?) -> Bool in if case .symbol = c?.icon { return true } else { return false } }
        if previous == nil || symbolsShown(previous) != symbolsShown(content) {
            needsLayout = true
            onHeightChange?()
        }
        applyColors()
    }

    static func opensInHint(_ content: Content) -> String {
        if content.opensIn.title == OpensIn.browserImUsing {
            return "Follows whichever browser was last in front."
        }
        if let profile = content.opensIn.title.components(separatedBy: " · ").dropFirst().first {
            return "Switches to an open tab first; \(profile) profile only for new tabs."
        }
        return "Switches to an open tab first."
    }

    private var showsSymbols: Bool {
        if case .symbol = content?.icon { return true }
        return false
    }

    var preferredHeight: CGFloat {
        layoutPieces(apply: false)
    }

    func focusName(selectAll: Bool = true) {
        window?.makeFirstResponder(nameField)
        if selectAll { nameField.currentEditor()?.selectAll(nil) }
    }

    private func applyColors() {
        footerLine.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
        meta.textColor = FlyoutColors.inkSecondary
        profileHint.textColor = FlyoutColors.inkSecondary
        nameField.refreshLook()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = Self.width - pad * 2
        bigTile.frame = NSRect(x: pad, y: pad, width: 44, height: 44)
        let fieldX = pad + 44 + 10
        nameField.frame = NSRect(x: fieldX, y: pad + 0.5, width: Self.width - pad - fieldX, height: 26)
        meta.frame = NSRect(x: fieldX + 2, y: pad + 26 + 3, width: Self.width - pad - fieldX - 2, height: 14)


        layoutPieces(apply: true)
    }

    /// Lays out the normal (not confirming) editor top to bottom and returns its height.
    /// Section labels sit on 16pt lines, like the concept's.
    @discardableResult
    private func layoutPieces(apply: Bool) -> CGFloat {
        let pad: CGFloat = 12, w = Self.width - pad * 2
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        var y: CGFloat = 56 + 12
        place(colorLabel, NSRect(x: pad + 2, y: y + 2, width: w, height: 13))
        y += 16 + 6
        var x = pad
        for swatch in swatches {
            place(swatch, NSRect(x: x - 3.5, y: y - 3.5, width: 27, height: 27))
            x += 20 + 5
        }
        y += 20 + 12
        place(iconLabel, NSRect(x: pad + 2, y: y + 2, width: w, height: 13))
        y += 16 + 6
        let choiceWidth = (w - 12) / 3
        for (i, choice) in iconChoices.enumerated() {
            place(choice, NSRect(x: pad + CGFloat(i) * (choiceWidth + 6), y: y, width: choiceWidth, height: 55))
        }
        y += 55
        if apply { for button in symbolButtons { button.isHidden = !showsSymbols } }
        if showsSymbols {
            y += 6
            for (i, button) in symbolButtons.enumerated() {
                place(button, NSRect(x: pad + CGFloat(i) * 29, y: y, width: 26, height: 24))
            }
            y += 24
        }
        y += 12
        place(profileLabel, NSRect(x: pad + 2, y: y + 2, width: w, height: 13))
        place(profileScope, NSRect(x: pad + w - 80, y: y + 1, width: 80, height: 14))
        y += 16 + 6
        place(profileRow, NSRect(x: pad, y: y, width: w, height: 26))
        y += 26 + 6
        let hintHeight = ceil(profileHint.attributedStringValue.boundingRect(with: NSSize(width: w - 4, height: 60),
                                                                              options: [.usesLineFragmentOrigin]).height)
        place(profileHint, NSRect(x: pad + 2, y: y, width: w - 2, height: hintHeight))
        y += hintHeight + 12
        place(footerLine, NSRect(x: pad, y: y, width: w, height: 1))
        y += 1 + 10
        let o = openButton.fittingWidth, sh = shareButton.fittingWidth, ex = exportButton.fittingWidth
        let dl = deleteButton.fittingWidth
        // Tight footers close the gaps before anything would overlap Delete.
        let gap = min(6, max(2, (w - o - sh - ex - dl) / 3))
        place(openButton, NSRect(x: pad, y: y, width: o, height: 24))
        place(shareButton, NSRect(x: pad + o + gap, y: y, width: sh, height: 24))
        place(exportButton, NSRect(x: pad + o + gap + sh + gap, y: y, width: ex, height: 24))
        place(deleteButton, NSRect(x: Self.width - pad - dl, y: y, width: dl, height: 24))
        y += 24
        return y + 12
    }

    // MARK: Actions

    @objc private func swatchTapped(_ sender: SwatchButton) {
        guard let id = sender.colorId else { return }
        onColor?(id)
    }

    @objc private func customTapped() { onCustomColor?() }

    @objc private func iconTapped(_ sender: IconChoiceButton) {
        switch sender.style {
        case .symbol:
            if case .symbol = content?.icon { return }
            onIcon?(.symbol(symbolButtons.first(where: \.isOn)?.symbol ?? "star"))
        default:
            onIcon?(sender.style)
        }
    }

    @objc private func symbolTapped(_ sender: SymbolButton) { onIcon?(.symbol(sender.symbol)) }
    @objc private func openTapped() { onOpen?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func exportTapped() { onExport?() }
    @objc private func deleteTapped() { onDelete?() }

    func controlTextDidChange(_ notification: Notification) {
        onRename?(nameField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }
}

// MARK: - Pieces

/// A 20pt color swatch; the last one is the conic "Custom color…" swatch.
private final class SwatchButton: FlyoutControl {
    let colorId: WorkspaceColorId?
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "selected" : nil) } }

    init(colorId: WorkspaceColorId?) {
        self.colorId = colorId
        super.init(frame: .zero)
        let name = colorId?.name ?? "Custom color…"
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
        let style: WorkspaceDot.Style = isOn || isFocused
            ? .ringed(ring: isFocused ? SettingsColors.accent : FlyoutColors.ink, gap: FlyoutColors.background)
            : .plain
        if let colorId {
            WorkspaceDot.draw(in: dot, color: colorId.color, style: style)
            return
        }
        WorkspaceDot.draw(in: dot, style: style) { dot in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: dot).addClip()
            for i in 0..<36 {
                let a0 = CGFloat(i) / 36 * 360, a1 = CGFloat(i + 1) / 36 * 360 + 1
                let wedge = NSBezierPath()
                wedge.move(to: NSPoint(x: dot.midX, y: dot.midY))
                wedge.appendArc(withCenter: NSPoint(x: dot.midX, y: dot.midY), radius: 11, startAngle: a0 - 90, endAngle: a1 - 90)
                wedge.close()
                NSColor(calibratedHue: CGFloat(i) / 36, saturation: 0.45, brightness: 1, alpha: 1).setFill()
                wedge.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Favicons · Letter · Symbol: a 26pt preview over its name.
private final class IconChoiceButton: FlyoutControl {
    let style: WorkspaceIcon
    private let mini = WorkspaceTileView()
    private let label = NSTextField(labelWithString: "")
    var preview: WorkspaceTileIdentity = .letter("?") { didSet { mini.identity = preview } }
    var colorId: WorkspaceColorId = .defaultColor() { didSet { mini.colorId = colorId } }
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "selected" : nil) } }

    init(style: WorkspaceIcon, title: String) {
        self.style = style
        super.init(frame: .zero)
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        mini.setAccessibilityElement(false)
        addSubview(mini)
        label.stringValue = title
        label.alignment = .center
        label.font = FlyoutFonts.ui(11)
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(title) icon")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mini.frame = NSRect(x: (bounds.width - 26) / 2, y: 6, width: 26, height: 26)
        label.frame = NSRect(x: 0, y: 6 + 26 + 4, width: bounds.width, height: 14)
    }

    override func updateLayer() {
        layer?.backgroundColor = flyoutCG(isHovered && !isOn ? FlyoutColors.hover : FlyoutColors.field)
        layer?.borderWidth = isFocused ? 2 : (isOn ? 1.5 : 0)
        layer?.borderColor = flyoutCG(isFocused ? SettingsColors.accent : FlyoutColors.ink)
        label.textColor = isOn ? FlyoutColors.ink : FlyoutColors.inkSecondary
        label.font = FlyoutFonts.ui(11, isOn ? .semibold : .regular)
    }
}

/// One of the eight symbols, shown once Symbol is chosen.
private final class SymbolButton: FlyoutControl {
    let symbol: String
    private let imageView = NSImageView()
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "selected" : nil) } }

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        toolTip = symbol
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func updateLayer() {
        layer?.backgroundColor = isOn ? flyoutCG(FlyoutColors.field) : (isHovered ? flyoutCG(FlyoutColors.field.withAlphaComponent(0.5)) : nil)
        layer?.borderWidth = isFocused ? 2 : (isOn ? 1 : 0)
        layer?.borderColor = flyoutCG(isFocused ? SettingsColors.accent : FlyoutColors.line)
        imageView.contentTintColor = isOn ? FlyoutColors.ink : FlyoutColors.inkSecondary
    }
}
