import AppKit

/// What a row shows. Built by the list controller from a `Node`.
struct NodeRowContent {
    enum Kind {
        case folder(isExpanded: Bool, childCount: Int)
        case link(favicon: NSImage?, domain: String?)
        case task(isCompleted: Bool, dueDate: Date?)
        case snippet(language: String?)
    }

    var kind: Kind
    var title: String
    var depth: Int
    var isArchived: Bool
    /// The link's site is open in a browser tab.
    var isOpen: Bool = false
    /// First lines of a snippet, for mosaic tiles.
    var codePreview: String? = nil

    var typeName: String {
        switch kind {
        case .folder: return "Folder"
        case .link: return "Link"
        case .task: return "Task"
        case .snippet: return "Snippet"
        }
    }
}

/// One list row: open-tab dot, type glyph, title, metadata and a trailing action slot.
/// Metadata sits at the trailing edge; hover actions, multi-select checks and jump
/// letters appear in the slot, and the metadata steps left to make room for them.
final class NodeRowView: BaseView {
    private let contentContainer = NSView()
    private let guidesView = GuideLinesView()
    private let disclosureButton = NSButton()
    private let iconView = NSImageView()
    private let editableTitle = InlineEditableTextField()
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeLabel = BadgeLabel()
    private let openDot = NSView()
    private let slotButton = NSButton()
    private let slotKeycap = NSTextField(labelWithString: "")
    private let swipeLeftActionView = NSImageView()
    private let swipeRightActionView = NSImageView()

    private var content: NodeRowContent?
    private var isSelected = false
    private var showsSlotAction = false
    private var jumpLetter: String?
    private var metrics = ListMetrics()
    private var onSlotAction: (() -> Void)?
    var onDisclosure: (() -> Void)?
    var isKeyboardFocused = false {
        didSet { if isKeyboardFocused != oldValue { updateVisualState() } }
    }

    private var disclosureLeadingConstraint: NSLayoutConstraint?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var contentLeadingConstraint: NSLayoutConstraint?
    /// Keeps the title clear of the metadata column (`rowS`: min(130, 36%) wide).
    private var titleTrailingReserve: NSLayoutConstraint?
    private var metaMaxWidth: NSLayoutConstraint?
    private var metaToEdge: NSLayoutConstraint?
    private var metaToSlot: NSLayoutConstraint?
    private var badgeToEdge: NSLayoutConstraint?
    private var badgeToSlot: NSLayoutConstraint?
    private var slotToEdge: NSLayoutConstraint?

    // Swipe state
    private var panGesture: NSPanGestureRecognizer?
    private var swipeDirection: SwipeDirection = .none
    private let swipeThreshold: CGFloat = 80
    private let maxSwipeDistance: CGFloat = 120
    var onSwipeRight: (() -> Void)?
    var onSwipeLeft: (() -> Void)?
    var swipeEnabled = true

    private enum SwipeDirection {
        case none, horizontal, vertical
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        layer?.cornerRadius = metrics.rowCornerRadius
        layer?.masksToBounds = true

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(pan)
        panGesture = pan

        for actionView in [swipeRightActionView, swipeLeftActionView] {
            actionView.translatesAutoresizingMaskIntoConstraints = false
            actionView.imageScaling = .scaleProportionallyDown
            actionView.wantsLayer = true
            actionView.isHidden = true
            addSubview(actionView)
        }

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = metrics.rowCornerRadius
        addSubview(contentContainer)

        contentLeadingConstraint = contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            contentLeadingConstraint!,
            contentContainer.widthAnchor.constraint(equalTo: widthAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            swipeRightActionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            swipeRightActionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            swipeRightActionView.widthAnchor.constraint(equalToConstant: 18),
            swipeRightActionView.heightAnchor.constraint(equalToConstant: 18),

            swipeLeftActionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            swipeLeftActionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            swipeLeftActionView.widthAnchor.constraint(equalToConstant: 18),
            swipeLeftActionView.heightAnchor.constraint(equalToConstant: 18),
        ])

        guidesView.translatesAutoresizingMaskIntoConstraints = false

        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        disclosureButton.target = self
        disclosureButton.action = #selector(handleDisclosure)
        disclosureButton.wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = metrics.iconCornerRadius
        iconView.layer?.masksToBounds = true

        editableTitle.translatesAutoresizingMaskIntoConstraints = false
        editableTitle.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        editableTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.alignment = .right
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)
        // Metadata gives way before the title does.
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)

        slotButton.translatesAutoresizingMaskIntoConstraints = false
        slotButton.isBordered = false
        slotButton.imagePosition = .imageOnly
        slotButton.target = self
        slotButton.action = #selector(handleSlotAction)
        slotButton.setButtonType(.momentaryChange)

        slotKeycap.translatesAutoresizingMaskIntoConstraints = false
        slotKeycap.font = StowTheme.Font.keycap
        slotKeycap.alignment = .center
        slotKeycap.wantsLayer = true
        slotKeycap.layer?.cornerRadius = 4
        slotKeycap.layer?.borderWidth = 1
        slotKeycap.isHidden = true

        openDot.translatesAutoresizingMaskIntoConstraints = false
        openDot.wantsLayer = true
        openDot.layer?.cornerRadius = 2
        openDot.isHidden = true

        for v in [guidesView, disclosureButton, openDot, iconView, editableTitle, metaLabel, badgeLabel, slotButton, slotKeycap] as [NSView] {
            contentContainer.addSubview(v)
        }

        disclosureLeadingConstraint = disclosureButton.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: metrics.leftPadding)
        titleTrailingReserve = editableTitle.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -8)
        metaMaxWidth = metaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 130)
        metaToEdge = metaLabel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8)
        metaToSlot = metaLabel.trailingAnchor.constraint(equalTo: slotButton.leadingAnchor, constant: -4)
        badgeToEdge = badgeLabel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -8)
        badgeToSlot = badgeLabel.trailingAnchor.constraint(equalTo: slotButton.leadingAnchor, constant: -4)
        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: metrics.leftPadding)
        slotToEdge = slotButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -6)

        NSLayoutConstraint.activate([
            guidesView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            guidesView.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),
            guidesView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            guidesView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            disclosureLeadingConstraint!,
            disclosureButton.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: metrics.disclosureWidth),
            disclosureButton.heightAnchor.constraint(equalToConstant: metrics.disclosureWidth),

            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: metrics.iconSize),

            editableTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: StowTheme.List.glyphToTitle - 2), // less the text cell's 2pt inset
            editableTitle.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            titleTrailingReserve!,

            metaLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            metaToEdge!,
            metaMaxWidth!,

            badgeLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            badgeToEdge!,

            openDot.widthAnchor.constraint(equalToConstant: 4),
            openDot.heightAnchor.constraint(equalToConstant: 4),
            openDot.trailingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -1.5),
            openDot.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            slotToEdge!,
            slotButton.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            slotButton.widthAnchor.constraint(equalToConstant: metrics.actionSlot),
            slotButton.heightAnchor.constraint(equalToConstant: metrics.actionSlot),

            slotKeycap.centerXAnchor.constraint(equalTo: slotButton.centerXAnchor),
            slotKeycap.centerYAnchor.constraint(equalTo: slotButton.centerYAnchor),
            slotKeycap.widthAnchor.constraint(equalToConstant: 16),
            slotKeycap.heightAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    // MARK: - Configuration

    func configure(content: NodeRowContent,
                   metrics: ListMetrics,
                   isSelected: Bool,
                   showSlotAction: Bool,
                   onSlotAction: (() -> Void)?) {
        self.content = content
        self.metrics = metrics
        self.isSelected = isSelected
        self.showsSlotAction = showSlotAction
        self.onSlotAction = onSlotAction

        let titleFont: NSFont
        if case .folder = content.kind { titleFont = metrics.folderTitleFont } else { titleFont = metrics.linkTitleFont }

        if editableTitle.isEditing {
            if editableTitle.text != content.title {
                cancelInlineRename()
                editableTitle.text = content.title
            }
        } else {
            editableTitle.text = content.title
        }
        editableTitle.font = titleFont
        editableTitle.textColor = metrics.titleColor

        disclosureLeadingConstraint?.constant = metrics.leftPadding + CGFloat(content.depth) * metrics.indentWidth
        iconLeadingConstraint?.constant = metrics.leftPadding + CGFloat(content.depth) * metrics.indentWidth
        guidesView.depth = content.depth
        guidesView.leftPadding = metrics.leftPadding
        guidesView.indent = metrics.indentWidth
        guidesView.color = metrics.colors.guide

        metaLabel.isHidden = true
        badgeLabel.isHidden = true
        var metaText: String?
        var metaColor = metrics.secondaryColor

        switch content.kind {
        case .folder(_, let childCount):
            setIcon(symbol: "folder", tint: metrics.iconTintColor)
            metaText = "\(childCount)"

        case .link(let favicon, let domain):
            if let favicon {
                favicon.isTemplate = false
                iconView.image = favicon
                iconView.contentTintColor = nil
            } else {
                iconView.image = SiteGlyph.tileImage(title: content.title, host: domain ?? "", size: metrics.iconSize)
                iconView.contentTintColor = nil
            }
            metaText = domain

        case .task(let isCompleted, let dueDate):
            setIcon(symbol: isCompleted ? "checkmark.circle.fill" : "circle", tint: isCompleted ? metrics.secondaryColor : metrics.iconTintColor)
            if isCompleted {
                editableTitle.attributedText = NSAttributedString(string: content.title, attributes: StowTheme.singleLineAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: metrics.secondaryColor,
                    .font: titleFont,
                ]))
            }
            if isCompleted {
                metaText = "done"
            } else if let dueDate {
                metaText = Self.dueFormatter.string(from: dueDate)
                if !isCompleted && dueDate < Calendar.current.startOfDay(for: Date()) {
                    metaColor = metrics.colors.overdue
                    metaText = "! " + (metaText ?? "")
                }
            }

        case .snippet(let language):
            setIcon(symbol: "chevron.left.forwardslash.chevron.right", tint: metrics.iconTintColor)
            if let language, !language.isEmpty {
                badgeLabel.isHidden = false
                badgeLabel.text = language
                badgeLabel.textColor = metrics.secondaryColor
                badgeLabel.strokeColor = metrics.colors.stroke
            }
        }

        if let metaText {
            metaLabel.stringValue = metaText
            metaLabel.textColor = metaColor
            metaLabel.isHidden = false
        }
        openDot.layer?.backgroundColor = resolvedCGColor(metrics.titleColor.withAlphaComponent(0.9))
        openDot.isHidden = !content.isOpen
        applyElasticMode(metrics.mode, content: content)
        needsLayout = true

        layer?.cornerRadius = metrics.rowCornerRadius
        contentContainer.layer?.cornerRadius = metrics.rowCornerRadius
        setAccessibilityLabel(accessibilityDescription(for: content))

        resetSwipe(animated: false)
        updateVisualState()
        refreshHoverState()
    }

    /// The list drops the trailing metadata; the sidebar keeps it. (The rail is RailView.)
    private func applyElasticMode(_ mode: ElasticMode, content: NodeRowContent) {
        guidesView.isHidden = true
        disclosureButton.isHidden = true
        if mode == .list {
            // Names only; folders keep their count.
            if case .folder = content.kind {} else { metaLabel.isHidden = true }
            badgeLabel.isHidden = true
        }
    }

    override func layout() {
        updateMetaColumn()
        super.layout()
    }

    /// The trailing column: 24pt for a folder count, else min(130, 36% of the row) when
    /// the row is wider than 210pt. The title never runs into it, as in the mockup.
    private func updateMetaColumn() {
        guard let content else { return }
        let width = bounds.width - CGFloat(content.depth) * metrics.indentWidth
        var column: CGFloat = 0
        if case .folder = content.kind {
            column = 24
        } else if metrics.mode != .list, width > 210 {
            column = min(130, (width * 0.36).rounded())
        }
        if !badgeLabel.isHidden {
            column = max(column, ceil(badgeLabel.fittingSize.width))
        } else if column == 0 {
            metaLabel.isHidden = true
        }
        let hasTrailing = !metaLabel.isHidden || !badgeLabel.isHidden
        metaMaxWidth?.constant = column
        let inset = Self.scrollerInset(for: enclosingScrollView)
        metaToEdge?.constant = -(8 + inset)
        badgeToEdge?.constant = -(8 + inset)
        slotToEdge?.constant = -(6 + inset)
        let slotShown = !slotButton.isHidden || !slotKeycap.isHidden
        let edge: CGFloat = inset + (slotShown ? 6 + metrics.actionSlot + 4 : 8)
        titleTrailingReserve?.constant = -(edge + (hasTrailing ? column + 6 : 0))
    }

    /// Room for an overlay scroller, which floats over the rows' trailing edge, so it
    /// never covers the meta column or the action slot.
    static func scrollerInset(for scrollView: NSScrollView?) -> CGFloat {
        guard let scrollView, scrollView.hasVerticalScroller, scrollView.scrollerStyle == .overlay else { return 0 }
        return NSScroller.scrollerWidth(for: scrollView.verticalScroller?.controlSize ?? .regular, scrollerStyle: .overlay)
    }

    static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private func setIcon(symbol: String, tint: NSColor) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        image?.isTemplate = true
        iconView.image = image
        iconView.contentTintColor = tint
    }

    private func accessibilityDescription(for content: NodeRowContent) -> String {
        var parts = [content.typeName, content.title]
        switch content.kind {
        case .folder(let isExpanded, let count):
            parts.append(isExpanded ? "expanded" : "collapsed")
            parts.append("\(count) items")
        case .link(_, let domain):
            if let domain { parts.append(domain) }
        case .task(let done, let due):
            parts.append(done ? "completed" : "not completed")
            if let due { parts.append("due \(Self.dueFormatter.string(from: due))") }
        case .snippet(let language):
            if let language { parts.append(language) }
        }
        if content.isOpen { parts.append("open in browser") }
        if content.isArchived { parts.append("archived") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    /// Shows a jump letter in the action slot, or nil to hide it.
    func setHintCharacter(_ hint: String?) {
        jumpLetter = hint
        updateVisualState()
    }

    func setSwipeRightIcon(_ symbolName: String, tintColor: NSColor) {
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon?.isTemplate = true
        swipeRightActionView.image = icon
        swipeRightActionView.contentTintColor = tintColor
    }

    func setSwipeLeftIcon(_ symbolName: String, tintColor: NSColor) {
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon?.isTemplate = true
        swipeLeftActionView.image = icon
        swipeLeftActionView.contentTintColor = tintColor
    }

    var isInlineRenaming: Bool {
        editableTitle.isEditing
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        editableTitle.beginInlineRename(
            onCommit: { [weak self] value in onCommit(value); self?.updateVisualState() },
            onCancel: { [weak self] in onCancel(); self?.updateVisualState() }
        )
        updateVisualState()
    }

    func cancelInlineRename() {
        editableTitle.cancelInlineRename()
        updateVisualState()
    }

    @objc private func handleSlotAction() {
        onSlotAction?()
    }

    @objc private func handleDisclosure() {
        onDisclosure?()
    }

    override func handleHoverStateChanged() {
        updateVisualState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVisualState()
        guidesView.needsDisplay = true
    }

    private func updateVisualState() {
        let isEditing = editableTitle.isEditing
        let fill: NSColor
        if isEditing {
            fill = metrics.colors.raised
        } else if isSelected {
            fill = metrics.selectedBackgroundColor
        } else if isHovered {
            fill = metrics.hoverBackgroundColor
        } else {
            fill = .clear
        }
        contentContainer.layer?.backgroundColor = resolvedCGColor(fill)
        contentContainer.layer?.borderWidth = (isEditing || isKeyboardFocused) ? 2 : 0
        contentContainer.layer?.borderColor = resolvedCGColor(metrics.colors.accent)

        // Action slot priority: jump letter, then multi-select check, then hover action.
        slotKeycap.isHidden = true
        slotButton.isHidden = true
        if let jumpLetter {
            slotKeycap.isHidden = false
            slotKeycap.stringValue = jumpLetter
            slotKeycap.textColor = metrics.titleColor
            slotKeycap.layer?.borderColor = resolvedCGColor(metrics.colors.stroke)
        } else if isSelected {
            slotButton.isHidden = false
            slotButton.isEnabled = false
            slotButton.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            slotButton.contentTintColor = metrics.colors.accent
        } else if isHovered && showsSlotAction && !isEditing {
            let archived = content?.isArchived ?? false
            let title = content?.title ?? ""
            slotButton.isHidden = false
            slotButton.isEnabled = true
            let label = archived ? "Put back \(title)" : "Archive \(title)"
            slotButton.image = NSImage(systemSymbolName: archived ? "arrow.uturn.backward" : "archivebox", accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            slotButton.contentTintColor = metrics.secondaryColor
            slotButton.toolTip = archived ? "Put Back" : "Archive (⌘⌫)"
            slotButton.setAccessibilityLabel(label)
        }
        let slotShown = !slotButton.isHidden || !slotKeycap.isHidden
        let off = slotShown ? [metaToEdge, badgeToEdge] : [metaToSlot, badgeToSlot]
        let on = slotShown ? [metaToSlot, badgeToSlot] : [metaToEdge, badgeToEdge]
        NSLayoutConstraint.deactivate(off.compactMap { $0 })
        NSLayoutConstraint.activate(on.compactMap { $0 })
        updateMetaColumn()
    }

    // MARK: - Swipe Gesture Handling

    @objc private func handlePanGesture(_ gesture: NSPanGestureRecognizer) {
        guard swipeEnabled, !editableTitle.isEditing else { return }

        let translation = gesture.translation(in: self)
        let velocity = gesture.velocity(in: self)

        switch gesture.state {
        case .began:
            swipeDirection = .none

        case .changed:
            if swipeDirection == .none {
                if abs(translation.x) > 5 || abs(translation.y) > 5 {
                    swipeDirection = abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
                }
            }

            guard swipeDirection == .horizontal else { return }

            let deltaX = translation.x

            let clampedDelta: CGFloat
            if abs(deltaX) > maxSwipeDistance {
                let overflow = abs(deltaX) - maxSwipeDistance
                let rubberBand = maxSwipeDistance + overflow * 0.3
                clampedDelta = deltaX > 0 ? rubberBand : -rubberBand
            } else {
                clampedDelta = deltaX
            }

            contentLeadingConstraint?.constant = clampedDelta

            swipeRightActionView.isHidden = clampedDelta <= 0
            swipeLeftActionView.isHidden = clampedDelta >= 0

            let pastThreshold = abs(clampedDelta) >= swipeThreshold
            if clampedDelta > 0 {
                swipeRightActionView.alphaValue = pastThreshold ? 1.0 : 0.5
            } else {
                swipeLeftActionView.alphaValue = pastThreshold ? 1.0 : 0.5
            }

            layoutSubtreeIfNeeded()

        case .ended, .cancelled:
            guard swipeDirection == .horizontal else {
                resetSwipe(animated: false)
                return
            }

            let offset = contentLeadingConstraint?.constant ?? 0

            if abs(offset) >= swipeThreshold || abs(velocity.x) > 500 {
                if offset > 0 {
                    onSwipeRight?()
                } else {
                    onSwipeLeft?()
                }
            }

            resetSwipe(animated: true)

        default:
            break
        }
    }

    private func resetSwipe(animated: Bool) {
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StowTheme.Motion.normal
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                contentLeadingConstraint?.constant = 0
                swipeRightActionView.isHidden = true
                swipeLeftActionView.isHidden = true
                layoutSubtreeIfNeeded()
            }
        } else {
            contentLeadingConstraint?.constant = 0
            swipeRightActionView.isHidden = true
            swipeLeftActionView.isHidden = true
        }
        swipeDirection = .none
    }
}

/// Vertical hierarchy guides, one per ancestor level, centered under each ancestor's disclosure.
private final class GuideLinesView: NSView {
    var depth = 0 { didSet { needsDisplay = true } }
    var leftPadding: CGFloat = 8
    var indent: CGFloat = 16
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard depth > 0 else { return }
        color.setFill()
        let scale = window?.backingScaleFactor ?? 2
        let width = 1 / scale * 2
        for level in 0..<depth {
            let x = leftPadding + CGFloat(level) * indent + StowTheme.List.disclosureWidth / 2
            NSRect(x: (x * scale).rounded() / scale, y: 0, width: width, height: bounds.height).fill()
        }
    }
}

/// A small outlined monospaced tag, used for snippet languages.
private final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }
    var textColor: NSColor = .secondaryLabelColor { didSet { label.textColor = textColor } }
    var strokeColor: NSColor = .separatorColor { didSet { updateLayer() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.badge
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = resolvedCGColor(strokeColor)
    }
}
