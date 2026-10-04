import AppKit

/// Notch, a headline, one sentence and one action, drawn in the workspace palette.
/// The whole area accepts links and text dragged in from other apps.
final class EmptyStateView: NSView {
    private let notch = NotchView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = EmptyStateButton()
    private let stack = NSStackView()
    private let dropOutline = CAShapeLayer()

    private(set) var copy: EmptyStateCopy?
    private var workspaceName = ""
    private var isDragging = false

    var colors: StowTheme.Colors? { didSet { applyColors() } }
    var onAction: ((EmptyStateAction) -> Void)?
    /// Builds the menu for `.addBookmarksMenu`.
    var menuProvider: (() -> NSMenu)?
    /// Text or URLs dropped onto the empty list.
    var onDropText: ((String) -> Void)?
    /// Whether the clipboard holds something Paste can add.
    var isPasteAvailable = true {
        didSet { if copy?.action == .paste { actionButton.isEnabled = isPasteAvailable } }
    }

    var actionView: NSView { actionButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        notch.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = StowTheme.Font.emptyTitle
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.isSelectable = false
        messageLabel.font = StowTheme.Font.emptyBody
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.isSelectable = false

        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.onHoverChanged = { [weak self] hovering in self?.notch.setHoveringAction(hovering) }

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [notch, titleLabel, messageLabel, actionButton] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(12, after: notch)
        stack.setCustomSpacing(14, after: messageLabel)
        // Under pressure the illustration goes first, then the sentence.
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: notch)
        stack.setVisibilityPriority(.init(rawValue: 600), for: messageLabel)
        addSubview(stack)

        // Margins and Notch's size yield in rail-width windows instead of setting a minimum.
        // Below the window-drag priority (510), or the copy's own width stops a live resize.
        let yielding: [NSLayoutConstraint] = [
            notch.widthAnchor.constraint(equalToConstant: 96),
            notch.heightAnchor.constraint(equalToConstant: 80),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ]
        yielding.forEach { $0.priority = .dragThatCannotResizeWindow }
        NSLayoutConstraint.activate(yielding + [
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])

        dropOutline.fillColor = nil
        dropOutline.lineWidth = 2
        dropOutline.lineDashPattern = [6, 4]
        dropOutline.isHidden = true
        layer?.addSublayer(dropOutline)

        registerForDraggedTypes([.URL, .string])
        setAccessibilityElement(false)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    func show(_ copy: EmptyStateCopy, workspaceName: String, animated: Bool) {
        let sceneChanged = copy.scene != self.copy?.scene
        self.copy = copy
        self.workspaceName = workspaceName
        titleLabel.stringValue = copy.title
        messageLabel.stringValue = copy.message
        stack.setAccessibilityLabel(copy.spokenLabel)

        actionButton.isHidden = copy.action == nil
        actionButton.title = copy.actionLabel ?? ""
        actionButton.keycap = copy.action == .paste ? "⌘V" : (copy.action == .clearSearch ? "esc" : nil)
        actionButton.showsMenuIndicator = copy.action == .addBookmarksMenu
        actionButton.setAccessibilityLabel(copy.actionAccessibilityLabel)
        actionButton.isEnabled = copy.action == .paste ? isPasteAvailable : true

        notch.setScene(copy.scene.notchScene, animated: animated && sceneChanged)
        if animated && sceneChanged && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for v in [titleLabel, messageLabel, actionButton] as [NSView] {
                v.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = StowTheme.Motion.fast
                for v in [titleLabel, messageLabel, actionButton] as [NSView] { v.animator().alphaValue = 1 }
            }
        } else {
            for v in [titleLabel, messageLabel, actionButton] as [NSView] { v.alphaValue = 1 }
        }
        applyColors()
    }

    /// Plays the first-item moment, then fades the empty state out.
    func playLandingAndDismiss(completion: @escaping () -> Void) {
        notch.playLanding { [weak self] in
            guard let self else { return completion() }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : StowTheme.Motion.normal
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.alphaValue = 1
                completion()
            })
        }
    }

    func settle() { notch.settle() }

    /// Forgets the shown state so the next appearance plays its entrance.
    func reset() {
        copy = nil
        notch.settle()
    }

    @objc private func actionTapped() {
        guard let action = copy?.action else { return }
        notch.hop()
        if action == .addBookmarksMenu, let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actionButton.bounds.height + 4), in: actionButton)
            return
        }
        onAction?(action)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        // Below these heights, Notch and then the sentence step aside so text never clips.
        notch.isHidden = bounds.height < 300 || bounds.width < 150
        messageLabel.isHidden = bounds.height < 200
        dropOutline.frame = bounds
        dropOutline.path = CGPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    private func applyColors() {
        guard let colors else { return }
        notch.colors = colors
        titleLabel.textColor = colors.inkPrimary
        messageLabel.textColor = colors.inkSecondary
        actionButton.colors = colors
        dropOutline.strokeColor = resolvedCGColor(colors.accent)
    }

    // MARK: - Drop target

    private func droppedText(from info: NSDraggingInfo) -> String? {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL],
           !urls.isEmpty {
            return urls.filter { !$0.isFileURL }.map(\.absoluteString).joined(separator: "\n")
        }
        return pb.string(forType: .string)
    }

    private func setDragging(_ dragging: Bool, info: NSDraggingInfo? = nil) {
        guard dragging != isDragging else { return }
        isDragging = dragging
        dropOutline.isHidden = !dragging
        notch.setOpen(dragging)
        actionButton.alphaValue = dragging ? 0 : 1
        if dragging {
            let host = info.flatMap(droppedText(from:)).flatMap { URL(string: $0.components(separatedBy: "\n")[0])?.host }
            titleLabel.stringValue = host.map { "Drop to add \($0)" } ?? "Drop to add to \(workspaceName)"
            messageLabel.stringValue = "It goes to the top of the list."
        } else if let copy {
            titleLabel.stringValue = copy.title
            messageLabel.stringValue = copy.message
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropText != nil, droppedText(from: sender)?.isEmpty == false else { return [] }
        setDragging(true, info: sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragging ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragging(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = droppedText(from: sender), !text.isEmpty else { return false }
        onDropText?(text)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        setDragging(false)
    }
}

/// The outlined empty-state action: 28pt, inkSecondary outline, hover and pressed fills,
/// an accent focus ring, and an optional keycap or menu chevron.
final class EmptyStateButton: BaseControl {
    private let label = NSTextField(labelWithString: "")
    private let keycapLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var colors: StowTheme.Colors? { didSet { updateAppearance() } }
    var onHoverChanged: ((Bool) -> Void)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    var keycap: String? {
        didSet { keycapLabel.stringValue = keycap ?? ""; keycapLabel.isHidden = keycap == nil }
    }
    var showsMenuIndicator = false { didSet { chevron.isHidden = !showsMenuIndicator } }

    override var isEnabled: Bool { didSet { updateAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = StowTheme.List.rowRadius
        layer?.borderWidth = 1
        setAccessibilityRole(.button)
        label.font = StowTheme.Font.control
        keycapLabel.font = StowTheme.Font.keycap
        keycapLabel.isHidden = true
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        chevron.isHidden = true
        let row = NSStackView(views: [label, keycapLabel, chevron])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateAppearance()
        onHoverChanged?(true)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateAppearance()
        onHoverChanged?(isHovered)
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { performAction() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        performAction()
        return true
    }

    override func handleHoverStateChanged() {
        updateAppearance()
        onHoverChanged?(isHovered && isEnabled)
    }

    override func handlePressedStateChanged() { updateAppearance() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private var isFocused: Bool { window?.firstResponder === self }

    private func updateAppearance() {
        guard let colors else { return }
        let fill: NSColor = !isEnabled ? .clear : (isPressed ? colors.multiSelected : (isHovered ? colors.hover : .clear))
        layer?.backgroundColor = resolvedCGColor(fill)
        layer?.borderWidth = isFocused ? 2 : 1
        layer?.borderColor = resolvedCGColor(isFocused ? colors.accent : colors.inkSecondary)
        let ink = isEnabled ? colors.inkPrimary : colors.inkSecondary
        label.textColor = ink
        keycapLabel.textColor = colors.inkSecondary
        chevron.contentTintColor = colors.inkSecondary
    }
}
