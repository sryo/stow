import AppKit

final class WorkspaceSwitcherView: NSView {
    struct Style {
        var textSize: CGFloat
        var textWeight: NSFont.Weight
        var unselectedTextColor: NSColor
        var unselectedTextOpacity: CGFloat
        var selectedBackgroundColor: NSColor
        var selectedTextColor: NSColor
        var hoverBackgroundOpacity: CGFloat
        var circleSize: CGFloat
        var circleBorderWidth: CGFloat
        var circleBorderColor: NSColor
        var circleBorderOpacity: CGFloat
        var circleTextGap: CGFloat
        var buttonHorizontalPadding: CGFloat
        var buttonVerticalPadding: CGFloat
        var buttonCornerRadius: CGFloat
        var buttonSpacing: CGFloat

        static var defaultStyle: Style {
            Style(
                textSize: 14,
                textWeight: .semibold,
                unselectedTextColor: ThemeConstants.Colors.darkGray,
                unselectedTextOpacity: ThemeConstants.Opacity.high,
                selectedBackgroundColor: ThemeConstants.Colors.darkGray,
                selectedTextColor: ThemeConstants.Colors.white,
                hoverBackgroundOpacity: ThemeConstants.Opacity.minimal,
                circleSize: ThemeConstants.Sizing.iconSmall,
                circleBorderWidth: 2,
                circleBorderColor: ThemeConstants.Colors.darkGray,
                circleBorderOpacity: 0.20,
                circleTextGap: ThemeConstants.Spacing.small,
                buttonHorizontalPadding: ThemeConstants.Spacing.regular,
                buttonVerticalPadding: ThemeConstants.Spacing.regular,
                buttonCornerRadius: ThemeConstants.CornerRadius.medium,
                buttonSpacing: ThemeConstants.Spacing.tiny
            )
        }

        var height: CGFloat {
            let font = NSFont.systemFont(ofSize: textSize, weight: textWeight)
            let textHeight = ceil(font.ascender - font.descender)
            return textHeight + (buttonVerticalPadding * 2)
        }
    }

    struct WorkspaceItem {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
    }

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let leftShadowView = NSView()
    private let rightShadowView = NSView()
    private var settingsButton: SettingsButton?
    private var workspaceButtons: [UUID: WorkspaceButton] = [:]
    private var orderedWorkspaceIds: [UUID] = []
    private var addButton: IconTitleButton?

    // Sliding highlight for swipe tracking
    private let slidingHighlight = NSView()
    private var isSlidingHighlightVisible = false

    // Inline rename tracking
    private weak var inlineRenameButton: WorkspaceButton?
    private var inlineRenameWorkspaceId: UUID?

    var style: Style {
        didSet {
            applyStyle()
        }
    }

    var workspaceColor: WorkspaceColorId = .defaultColor() {
        didSet {
            updateShadows()
        }
    }

    /// Override color for shadow gradients during swipe. Set to nil to use workspaceColor.
    var swipeShadowColor: NSColor? {
        didSet {
            updateShadows()
        }
    }

    var workspaces: [WorkspaceItem] = [] {
        didSet {
            rebuildButtons()
        }
    }

    var selectedWorkspaceId: UUID? {
        didSet {
            updateSelection()
        }
    }

    var isSettingsSelected: Bool = false {
        didSet {
            updateSelection()
        }
    }

    /// When set (non-nil), shows a sliding highlight that interpolates between button positions.
    /// Page offset 0 = settings, 1..N = workspaces, N+1 = add button.
    /// Set to nil when the swipe ends to restore normal selection.
    var visualPageOffset: CGFloat? {
        didSet {
            updateSlidingHighlight()
        }
    }

    var onWorkspaceSelected: ((UUID) -> Void)?
    var onWorkspaceRightClick: ((UUID, NSPoint) -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onWorkspaceRename: ((UUID, String) -> Void)?
    var onSettingsSelected: (() -> Void)?

    init(style: Style = .defaultStyle) {
        self.style = style
        super.init(frame: .zero)
        setupView()
        applyStyle()
    }

    required init?(coder: NSCoder) {
        self.style = .defaultStyle
        super.init(coder: coder)
        setupView()
        applyStyle()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: style.height)
    }

    private func setupView() {
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true

        contentView.translatesAutoresizingMaskIntoConstraints = false

        // Setup sliding highlight (behind buttons)
        slidingHighlight.wantsLayer = true
        slidingHighlight.layer?.backgroundColor = style.selectedBackgroundColor.cgColor
        slidingHighlight.layer?.cornerRadius = style.buttonCornerRadius
        slidingHighlight.isHidden = true
        contentView.addSubview(slidingHighlight)

        scrollView.documentView = contentView
        addSubview(scrollView)

        // Setup shadow views
        leftShadowView.translatesAutoresizingMaskIntoConstraints = false
        leftShadowView.wantsLayer = true
        rightShadowView.translatesAutoresizingMaskIntoConstraints = false
        rightShadowView.wantsLayer = true

        addSubview(leftShadowView)
        addSubview(rightShadowView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            leftShadowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftShadowView.topAnchor.constraint(equalTo: topAnchor),
            leftShadowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftShadowView.widthAnchor.constraint(equalToConstant: 32),

            rightShadowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightShadowView.topAnchor.constraint(equalTo: topAnchor),
            rightShadowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightShadowView.widthAnchor.constraint(equalToConstant: 32)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        updateShadows()
    }

    private func applyStyle() {
        invalidateIntrinsicContentSize()
        rebuildButtons()
    }

    private func rebuildButtons() {
        // Remove all existing buttons
        settingsButton?.removeFromSuperview()
        settingsButton = nil
        for (_, button) in workspaceButtons {
            button.removeFromSuperview()
        }
        workspaceButtons.removeAll()
        orderedWorkspaceIds.removeAll()
        addButton?.removeFromSuperview()
        addButton = nil

        // Create settings button first
        let settingsBtn = SettingsButton(style: style)
        settingsBtn.translatesAutoresizingMaskIntoConstraints = false
        settingsBtn.onTap = { [weak self] in
            self?.onSettingsSelected?()
        }

        contentView.addSubview(settingsBtn)
        settingsButton = settingsBtn

        NSLayoutConstraint.activate([
            settingsBtn.topAnchor.constraint(equalTo: contentView.topAnchor),
            settingsBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            settingsBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        ])

        var previousView: NSView? = settingsBtn

        // Create workspace buttons
        for workspace in workspaces {
            let button = WorkspaceButton(
                workspaceId: workspace.id,
                name: workspace.name,
                colorId: workspace.colorId,
                style: style
            )
            button.translatesAutoresizingMaskIntoConstraints = false
            button.onTap = { [weak self] id in
                self?.onWorkspaceSelected?(id)
            }
            button.onRightClick = { [weak self] id, point in
                self?.onWorkspaceRightClick?(id, point)
            }

            contentView.addSubview(button)
            workspaceButtons[workspace.id] = button
            orderedWorkspaceIds.append(workspace.id)

            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])

            if let prev = previousView {
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: style.buttonSpacing)
                ])
            } else {
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
                ])
            }

            previousView = button
        }

        // Create "Add new workspace" button
        let addBtn = IconTitleButton(
            title: "New workspace",
            symbolName: "plus",
            style: .addWorkspace
        )
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.target = self
        addBtn.action = #selector(addWorkspaceTapped)

        contentView.addSubview(addBtn)
        addButton = addBtn

        NSLayoutConstraint.activate([
            addBtn.topAnchor.constraint(equalTo: contentView.topAnchor),
            addBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        if let prev = previousView {
            NSLayoutConstraint.activate([
                addBtn.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: style.buttonSpacing)
            ])
        } else {
            NSLayoutConstraint.activate([
                addBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
            ])
        }

        NSLayoutConstraint.activate([
            addBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        updateSelection()
    }

    private func updateSelection() {
        // During swipe, hide discrete selection — the sliding highlight takes over
        let showDiscrete = visualPageOffset == nil
        settingsButton?.isSelected = showDiscrete && isSettingsSelected
        for (id, button) in workspaceButtons {
            button.isSelected = showDiscrete && (id == selectedWorkspaceId) && !isSettingsSelected
        }
    }

    private func updateSlidingHighlight() {
        guard let offset = visualPageOffset else {
            // Swipe ended — hide highlight and restore normal selection
            slidingHighlight.isHidden = true
            isSlidingHighlightVisible = false
            // Reset swipe text colors
            for (_, button) in workspaceButtons {
                button.setSwipeTextColor(nil)
            }
            settingsButton?.setSwipeTextColor(nil)
            addButton?.setSwipeTextColor(nil, selectedColor: style.selectedTextColor)
            updateSelection()
            return
        }

        // Show sliding highlight and hide discrete selection
        if !isSlidingHighlightVisible {
            isSlidingHighlightVisible = true
            updateSelection()
        }
        slidingHighlight.isHidden = false

        // Need layout to be up to date for frame calculations
        contentView.layoutSubtreeIfNeeded()

        // Get frames for the "from" and "to" buttons
        let fromFrame = frameForPageButton(Int(floor(offset)))
        let toFrame = frameForPageButton(Int(ceil(offset)))
        let fraction = offset - floor(offset)

        // Interpolate position and size
        let x = fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * fraction
        let width = fromFrame.width + (toFrame.width - fromFrame.width) * fraction
        let height = fromFrame.height
        let y = fromFrame.origin.y

        slidingHighlight.frame = NSRect(x: x, y: y, width: width, height: height)

        // Interpolate button text colors based on overlap with sliding highlight
        let highlightFrame = slidingHighlight.frame
        for (_, button) in workspaceButtons {
            let overlap = highlightFrame.intersection(button.frame)
            if overlap.isNull || overlap.width < 1 {
                button.setSwipeTextColor(nil)
            } else {
                let fraction = overlap.width / button.frame.width
                button.setSwipeTextColor(fraction)
            }
        }
        // Also handle settings button
        if let settings = settingsButton {
            let overlap = highlightFrame.intersection(settings.frame)
            if overlap.isNull || overlap.width < 1 {
                settings.setSwipeTextColor(nil)
            } else {
                let fraction = overlap.width / settings.frame.width
                settings.setSwipeTextColor(fraction)
            }
        }
        // Also handle add button
        if let addBtn = addButton {
            let overlap = highlightFrame.intersection(addBtn.frame)
            if overlap.isNull || overlap.width < 1 {
                addBtn.setSwipeTextColor(nil, selectedColor: style.selectedTextColor)
            } else {
                let fraction = overlap.width / addBtn.frame.width
                addBtn.setSwipeTextColor(fraction, selectedColor: style.selectedTextColor)
            }
        }

        // Auto-scroll to keep highlight visible
        let highlightCenter = x + width / 2
        let visibleRect = scrollView.contentView.documentVisibleRect
        if highlightCenter < visibleRect.minX + 40 || highlightCenter > visibleRect.maxX - 40 {
            let targetX = max(0, highlightCenter - visibleRect.width / 2)
            scrollView.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        }
    }

    /// Returns the frame of the button corresponding to a page index.
    private func frameForPageButton(_ pageIndex: Int) -> NSRect {
        let clamped = max(0, pageIndex)

        if clamped == 0 {
            return settingsButton?.frame ?? .zero
        }

        let workspaceIdx = clamped - 1
        if workspaceIdx < orderedWorkspaceIds.count {
            let id = orderedWorkspaceIds[workspaceIdx]
            return workspaceButtons[id]?.frame ?? .zero
        }

        // Add button (last page)
        return addButton?.frame ?? .zero
    }

    @objc private func scrollViewDidScroll() {
        updateShadows()
        // Refresh hover states for all buttons when scrolling
        for (_, button) in workspaceButtons {
            button.refreshHoverState()
        }
    }

    @objc private func addWorkspaceTapped() {
        onAddWorkspace?()
    }

    private func updateShadows() {
        let clipView = scrollView.contentView

        let visibleRect = clipView.documentVisibleRect
        let contentWidth = contentView.bounds.width

        let canScrollLeft = visibleRect.origin.x > 0
        let canScrollRight = visibleRect.origin.x + visibleRect.width < contentWidth

        // Create gradients based on workspace color (or swipe override)
        let baseColor = swipeShadowColor ?? workspaceColor.color

        let shadowGradientOpacity = 0.80

        if canScrollLeft {
            let leftGradient = CAGradientLayer()
            leftGradient.frame = leftShadowView.bounds
            leftGradient.colors = [
                baseColor.withAlphaComponent(shadowGradientOpacity).cgColor,
                baseColor.withAlphaComponent(0.0).cgColor
            ]
            leftGradient.startPoint = CGPoint(x: 0, y: 0.5)
            leftGradient.endPoint = CGPoint(x: 1, y: 0.5)
            leftShadowView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            leftShadowView.layer?.addSublayer(leftGradient)
            leftShadowView.isHidden = false
        } else {
            leftShadowView.isHidden = true
        }

        if canScrollRight {
            let rightGradient = CAGradientLayer()
            rightGradient.frame = rightShadowView.bounds
            rightGradient.colors = [
                baseColor.withAlphaComponent(0.0).cgColor,
                baseColor.withAlphaComponent(shadowGradientOpacity).cgColor
            ]
            rightGradient.startPoint = CGPoint(x: 0, y: 0.5)
            rightGradient.endPoint = CGPoint(x: 1, y: 0.5)
            rightShadowView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            rightShadowView.layer?.addSublayer(rightGradient)
            rightShadowView.isHidden = false
        } else {
            rightShadowView.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        updateShadows()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Inline Rename

    func beginInlineRename(workspaceId: UUID) {
        cancelInlineRename()
        guard let button = workspaceButtons[workspaceId] else { return }

        inlineRenameWorkspaceId = workspaceId
        inlineRenameButton = button
        button.beginInlineRename(onCommit: { [weak self] newName in
            self?.commitInlineRename(newName)
        }, onCancel: { [weak self] in
            self?.handleInlineRenameCancelled()
        })
    }

    func cancelInlineRename() {
        guard inlineRenameWorkspaceId != nil else { return }
        inlineRenameButton?.cancelInlineRename()
        clearInlineRenameState()
    }

    private func commitInlineRename(_ newName: String) {
        guard let workspaceId = inlineRenameWorkspaceId else {
            clearInlineRenameState()
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handleInlineRenameCancelled()
            return
        }
        onWorkspaceRename?(workspaceId, trimmed)
        clearInlineRenameState()
    }

    private func handleInlineRenameCancelled() {
        clearInlineRenameState()
    }

    private func clearInlineRenameState() {
        inlineRenameButton = nil
        inlineRenameWorkspaceId = nil
    }
}

// MARK: - SettingsButton

private final class SettingsButton: BaseControl {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(string: "Settings")
    private let style: WorkspaceSwitcherView.Style

    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    var onTap: (() -> Void)?

    init(style: WorkspaceSwitcherView.Style) {
        self.style = style
        super.init(frame: .zero)

        layer?.masksToBounds = true

        // Setup icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.circleSize, weight: .regular)

        // Setup title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.focusRingType = .none
        titleLabel.stringValue = "Settings"
        titleLabel.font = NSFont.systemFont(ofSize: style.textSize, weight: style.textWeight)

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.buttonHorizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: style.circleSize),
            iconView.heightAnchor.constraint(equalToConstant: style.circleSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: style.circleTextGap),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.buttonHorizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func handleHoverStateChanged() {
        updateAppearance()
    }

    override func performAction() {
        onTap?()
    }

    /// Sets text/icon color during swipe based on overlap fraction (0 = unselected, 1 = fully selected).
    /// Pass nil to restore default unselected appearance.
    func setSwipeTextColor(_ fraction: CGFloat?) {
        guard let fraction else {
            let color = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
            titleLabel.textColor = color
            iconView.contentTintColor = color
            return
        }
        let from = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
        if let blended = from.blended(withFraction: fraction, of: style.selectedTextColor) {
            titleLabel.textColor = blended
            iconView.contentTintColor = blended
        }
    }

    private func updateAppearance() {
        let iconColor = style.unselectedTextColor
        if isSelected {
            layer?.backgroundColor = style.selectedBackgroundColor.cgColor
            titleLabel.textColor = style.selectedTextColor
            iconView.contentTintColor = style.selectedTextColor
            layer?.cornerRadius = style.buttonCornerRadius
        } else if isHovered {
            layer?.backgroundColor = style.unselectedTextColor.withAlphaComponent(style.hoverBackgroundOpacity).cgColor
            titleLabel.textColor = iconColor.withAlphaComponent(style.unselectedTextOpacity)
            iconView.contentTintColor = iconColor.withAlphaComponent(style.unselectedTextOpacity)
            layer?.cornerRadius = style.buttonCornerRadius
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = iconColor.withAlphaComponent(style.unselectedTextOpacity)
            iconView.contentTintColor = iconColor.withAlphaComponent(style.unselectedTextOpacity)
            layer?.cornerRadius = style.buttonCornerRadius
        }
    }
}

// MARK: - WorkspaceButton

private final class WorkspaceButton: BaseControl {
    private let workspaceId: UUID
    private let circleView = NSView()
    private let titleLabel = NSTextField(string: "")
    private let style: WorkspaceSwitcherView.Style

    // Inline editing state
    private var isEditingTitle = false
    private var editingOriginalTitle: String?
    private var onEditCommit: ((String) -> Void)?
    private var onEditCancel: (() -> Void)?
    private var titleLabelWidthConstraint: NSLayoutConstraint?

    // Fixed width for text field during inline editing (easily adjustable)
    private let editingTextFieldWidth: CGFloat = 170

    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    var isInlineRenaming: Bool {
        isEditingTitle
    }

    var onTap: ((UUID) -> Void)?
    var onRightClick: ((UUID, NSPoint) -> Void)?

    init(workspaceId: UUID, name: String, colorId: WorkspaceColorId, style: WorkspaceSwitcherView.Style) {
        self.workspaceId = workspaceId
        self.style = style
        super.init(frame: .zero)

        layer?.masksToBounds = true

        // Setup circle
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.wantsLayer = true
        circleView.layer?.masksToBounds = true
        circleView.layer?.cornerRadius = style.circleSize / 2
        circleView.layer?.backgroundColor = colorId.color.cgColor
        circleView.layer?.borderWidth = style.circleBorderWidth
        circleView.layer?.borderColor = style.circleBorderColor.withAlphaComponent(style.circleBorderOpacity).cgColor

        // Setup title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.focusRingType = .none
        titleLabel.stringValue = name
        titleLabel.font = NSFont.systemFont(ofSize: style.textSize, weight: style.textWeight)

        addSubview(circleView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            circleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.buttonHorizontalPadding),
            circleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            circleView.widthAnchor.constraint(equalToConstant: style.circleSize),
            circleView.heightAnchor.constraint(equalToConstant: style.circleSize),

            titleLabel.leadingAnchor.constraint(equalTo: circleView.trailingAnchor, constant: style.circleTextGap),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.buttonHorizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func handleHoverStateChanged() {
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(workspaceId)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(workspaceId, event.locationInWindow)
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = style.selectedBackgroundColor.cgColor
            titleLabel.textColor = style.selectedTextColor
            layer?.cornerRadius = style.buttonCornerRadius
        } else if isHovered {
            layer?.backgroundColor = style.unselectedTextColor.withAlphaComponent(style.hoverBackgroundOpacity).cgColor
            titleLabel.textColor = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
            layer?.cornerRadius = style.buttonCornerRadius
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
            layer?.cornerRadius = style.buttonCornerRadius
        }
    }

    /// Sets text color during swipe based on overlap fraction (0 = unselected, 1 = fully selected).
    /// Pass nil to restore default unselected appearance.
    func setSwipeTextColor(_ fraction: CGFloat?) {
        guard let fraction else {
            titleLabel.textColor = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
            return
        }
        let from = style.unselectedTextColor.withAlphaComponent(style.unselectedTextOpacity)
        if let blended = from.blended(withFraction: fraction, of: style.selectedTextColor) {
            titleLabel.textColor = blended
        }
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard !isEditingTitle else { return }
        isEditingTitle = true
        editingOriginalTitle = titleLabel.stringValue
        onEditCommit = onCommit
        onEditCancel = onCancel

        // Set fixed width for editing
        titleLabelWidthConstraint = titleLabel.widthAnchor.constraint(equalToConstant: editingTextFieldWidth)
        titleLabelWidthConstraint?.isActive = true

        // Preserve font when switching to editable mode
        let currentFont = titleLabel.font ?? NSFont.systemFont(ofSize: style.textSize, weight: style.textWeight)
        titleLabel.isEditable = true
        titleLabel.isSelectable = true
        titleLabel.font = currentFont
        titleLabel.delegate = self

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.titleLabel)
            if let editor = self.titleLabel.currentEditor() {
                // Ensure font is set on the field editor as well
                editor.font = currentFont
                let length = (self.titleLabel.stringValue as NSString).length
                editor.selectedRange = NSRange(location: 0, length: length)
            }
        }
    }

    func cancelInlineRename() {
        guard isEditingTitle else { return }
        titleLabel.stringValue = editingOriginalTitle ?? titleLabel.stringValue
        finishInlineRename(commit: false)
        if window?.firstResponder == titleLabel.currentEditor() {
            window?.makeFirstResponder(nil)
        }
    }

    private func finishInlineRename(commit: Bool) {
        let commitHandler = onEditCommit
        let cancelHandler = onEditCancel
        let finalValue = titleLabel.stringValue

        // Remove fixed width constraint
        titleLabelWidthConstraint?.isActive = false
        titleLabelWidthConstraint = nil

        isEditingTitle = false
        editingOriginalTitle = nil
        onEditCommit = nil
        onEditCancel = nil
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.delegate = nil

        // Ensure font is maintained after editing
        titleLabel.font = NSFont.systemFont(ofSize: style.textSize, weight: style.textWeight)

        if commit {
            commitHandler?(finalValue)
        } else {
            cancelHandler?()
        }
    }
}

// MARK: - WorkspaceButton + NSTextFieldDelegate

extension WorkspaceButton: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingTitle else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int ?? NSOtherTextMovement
        let trimmed = titleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if movement == NSCancelTextMovement {
            // Escape key: always cancel and restore original text
            titleLabel.stringValue = editingOriginalTitle ?? titleLabel.stringValue
            finishInlineRename(commit: false)
        } else if !trimmed.isEmpty {
            // Return key or focus loss with non-empty text: commit
            titleLabel.stringValue = trimmed
            finishInlineRename(commit: true)
        } else {
            // Focus loss or return with empty text: cancel and restore original
            titleLabel.stringValue = editingOriginalTitle ?? titleLabel.stringValue
            finishInlineRename(commit: false)
        }
    }
}

