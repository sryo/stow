import AppKit

final class NodeRowView: BaseView {
    private let contentContainer = NSView()
    private let iconView = NSImageView()
    private let editableTitle = InlineEditableTextField()
    private let deleteButton = NSButton()
    private let dueDateLabel = NSTextField(labelWithString: "")
    private let swipeLeftActionView = NSImageView()
    private let swipeRightActionView = NSImageView()
    private var isSelected = false
    private var showsDeleteButton = false
    private var metrics = ListMetrics()
    private var onDelete: (() -> Void)?
    private var iconLeadingConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var contentLeadingConstraint: NSLayoutConstraint?

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

        // Pan gesture for swipe
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(pan)
        panGesture = pan

        // Swipe action backgrounds
        swipeRightActionView.translatesAutoresizingMaskIntoConstraints = false
        swipeRightActionView.imageScaling = .scaleProportionallyDown
        swipeRightActionView.wantsLayer = true
        let rightIcon = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        rightIcon?.isTemplate = true
        swipeRightActionView.image = rightIcon
        swipeRightActionView.contentTintColor = .systemGreen
        swipeRightActionView.isHidden = true

        swipeLeftActionView.translatesAutoresizingMaskIntoConstraints = false
        swipeLeftActionView.imageScaling = .scaleProportionallyDown
        swipeLeftActionView.wantsLayer = true
        let leftIcon = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        leftIcon?.isTemplate = true
        swipeLeftActionView.image = leftIcon
        swipeLeftActionView.contentTintColor = .systemRed
        swipeLeftActionView.isHidden = true

        addSubview(swipeRightActionView)
        addSubview(swipeLeftActionView)

        // Content container (moves during swipe)
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        addSubview(contentContainer)

        contentLeadingConstraint = contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            contentLeadingConstraint!,
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            swipeRightActionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            swipeRightActionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            swipeRightActionView.widthAnchor.constraint(equalToConstant: 24),
            swipeRightActionView.heightAnchor.constraint(equalToConstant: 24),

            swipeLeftActionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            swipeLeftActionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            swipeLeftActionView.widthAnchor.constraint(equalToConstant: 24),
            swipeLeftActionView.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Setup content views inside container
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = metrics.iconCornerRadius
        iconView.layer?.masksToBounds = true

        editableTitle.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.isBordered = false
        let deleteIconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(deleteIconConfig)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.setButtonType(.momentaryChange)

        dueDateLabel.translatesAutoresizingMaskIntoConstraints = false
        dueDateLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        dueDateLabel.isHidden = true
        dueDateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dueDateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentContainer.addSubview(iconView)
        contentContainer.addSubview(editableTitle)
        contentContainer.addSubview(dueDateLabel)
        contentContainer.addSubview(deleteButton)

        iconLeadingConstraint = iconView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 16)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 26)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 26)

        NSLayoutConstraint.activate([
            iconLeadingConstraint!,
            iconView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            iconWidthConstraint!,
            iconHeightConstraint!,

            editableTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            editableTitle.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            editableTitle.trailingAnchor.constraint(lessThanOrEqualTo: dueDateLabel.leadingAnchor, constant: -8),

            dueDateLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            dueDateLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),

            deleteButton.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),
            deleteButton.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func configure(title: String,
                   icon: NSImage?,
                   titleFont: NSFont,
                   showDelete: Bool,
                   metrics: ListMetrics,
                   onDelete: (() -> Void)?,
                   isSelected: Bool,
                   isCompleted: Bool = false,
                   dueDate: Date? = nil) {
        self.metrics = metrics
        self.isSelected = isSelected
        updateVisualState()
        if editableTitle.isEditing {
            if editableTitle.text != title {
                cancelInlineRename()
                editableTitle.text = title
            }
        } else {
            editableTitle.text = title
        }
        editableTitle.font = titleFont

        // Apply completed styling
        if isCompleted {
            editableTitle.textColor = metrics.titleColor.withAlphaComponent(0.4)
            let attributedString = NSAttributedString(
                string: title,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: metrics.titleColor.withAlphaComponent(0.4),
                    .font: titleFont
                ]
            )
            editableTitle.attributedText = attributedString
        } else {
            editableTitle.textColor = metrics.titleColor
        }

        iconView.image = icon
        if let icon {
            iconView.contentTintColor = icon.isTemplate ? metrics.iconTintColor : nil
        }

        // Due date label
        if let dueDate {
            dueDateLabel.isHidden = false
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            dueDateLabel.stringValue = formatter.string(from: dueDate)
            dueDateLabel.textColor = dueDate < Date() ? NSColor.systemRed : metrics.titleColor.withAlphaComponent(0.6)
        } else {
            dueDateLabel.isHidden = true
        }

        layer?.cornerRadius = metrics.rowCornerRadius
        iconView.layer?.cornerRadius = metrics.iconCornerRadius
        deleteButton.contentTintColor = metrics.deleteTintColor
        iconWidthConstraint?.constant = metrics.iconSize
        iconHeightConstraint?.constant = metrics.iconSize

        showsDeleteButton = showDelete
        self.onDelete = onDelete

        // Reset swipe state
        resetSwipe(animated: false)

        refreshHoverState()
    }

    func setIndentation(depth: Int, metrics: ListMetrics) {
        iconLeadingConstraint?.constant = metrics.leftPadding + CGFloat(depth) * metrics.indentWidth
    }

    func setSwipeRightIcon(_ symbolName: String, tintColor: NSColor) {
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon?.isTemplate = true
        swipeRightActionView.image = icon
        swipeRightActionView.contentTintColor = tintColor
    }

    var isInlineRenaming: Bool {
        editableTitle.isEditing
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        editableTitle.beginInlineRename(onCommit: onCommit, onCancel: onCancel)
    }

    func cancelInlineRename() {
        editableTitle.cancelInlineRename()
    }

    @objc private func handleDelete() {
        onDelete?()
    }

    override func handleHoverStateChanged() {
        updateVisualState()
    }

    private func updateVisualState() {
        if isSelected {
            contentContainer.layer?.backgroundColor = metrics.selectedBackgroundColor.cgColor
            deleteButton.isHidden = true
        } else if isHovered {
            contentContainer.layer?.backgroundColor = metrics.hoverBackgroundColor.cgColor
            deleteButton.isHidden = !showsDeleteButton
        } else {
            contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
            deleteButton.isHidden = true
        }
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
            // Directional locking on first significant movement
            if swipeDirection == .none {
                if abs(translation.x) > 5 || abs(translation.y) > 5 {
                    swipeDirection = abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
                }
            }

            guard swipeDirection == .horizontal else { return }

            let deltaX = translation.x

            // Rubber-band effect at edges
            let clampedDelta: CGFloat
            if abs(deltaX) > maxSwipeDistance {
                let overflow = abs(deltaX) - maxSwipeDistance
                let rubberBand = maxSwipeDistance + overflow * 0.3
                clampedDelta = deltaX > 0 ? rubberBand : -rubberBand
            } else {
                clampedDelta = deltaX
            }

            contentLeadingConstraint?.constant = clampedDelta

            // Show/hide action icons
            swipeRightActionView.isHidden = clampedDelta <= 0
            swipeLeftActionView.isHidden = clampedDelta >= 0

            // Visual feedback at threshold
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
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
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
