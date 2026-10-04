import AppKit

/// The title-bar workspace control: a workspace button (dot, name, chevron) that opens a
/// numbered workspace menu, page dots that track trackpad swiping (Settings is the first
/// page), and a button for a new workspace.
///
/// Page indices match the pager: 0 is Settings, workspaces start at 1.
@MainActor
final class WorkspaceBarView: NSView {
    struct WorkspaceItem: Equatable {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
    }

    var workspaces: [WorkspaceItem] = [] {
        didSet { if workspaces != oldValue { rebuildDots(); updateTitle() } }
    }
    var selectedWorkspaceId: UUID? {
        didSet { updateTitle(); updateDots() }
    }
    var isSettingsSelected = false {
        didSet { updateTitle(); updateDots() }
    }
    var workspaceColor: WorkspaceColorId = .defaultColor() {
        didSet { colors = StowTheme.colors(for: workspaceColor, tint: StowTheme.displayTint) }
    }
    /// Fractional page offset while the user is swiping, nil otherwise.
    var visualPageOffset: CGFloat? {
        didSet { updateDots() }
    }

    var onWorkspaceSelected: ((UUID) -> Void)?
    var onWorkspaceRightClick: ((UUID, NSPoint) -> Void)?
    var onAddWorkspace: (() -> Void)?
    var onWorkspaceRename: ((UUID, String) -> Void)?
    var onSettingsSelected: (() -> Void)?

    private var colors = StowTheme.colors(for: .defaultColor()) {
        didSet { applyColors() }
    }

    private let workspaceButton = WorkspaceMenuButton()
    private let dotsView = PageDotsView()
    private let addButton = NSButton()
    private let addHint = NSTextField(labelWithString: "⌘N")

    /// While true (⌘ held), the dots show their ⌘ numbers and "+" shows ⌘N.
    var showsShortcutHints = false {
        didSet {
            addHint.isHidden = !showsShortcutHints
            dotsView.showsNumbers = showsShortcutHints
        }
    }
    private var renamingWorkspaceId: UUID?

    var isInlineRenaming: Bool { renamingWorkspaceId != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        workspaceButton.translatesAutoresizingMaskIntoConstraints = false
        workspaceButton.target = self
        workspaceButton.action = #selector(showWorkspaceMenu)
        workspaceButton.onRightClick = { [weak self] point in
            guard let self, let id = self.selectedWorkspaceId, !self.isSettingsSelected else { return }
            self.onWorkspaceRightClick?(id, self.workspaceButton.convert(point, to: nil))
        }
        workspaceButton.onDoubleClick = { [weak self] in
            guard let self, let id = self.selectedWorkspaceId, !self.isSettingsSelected else { return }
            self.beginInlineRename(workspaceId: id)
        }

        dotsView.translatesAutoresizingMaskIntoConstraints = false
        dotsView.onSelectPage = { [weak self] page in
            guard let self else { return }
            if page == 0 { self.onSettingsSelected?() }
            else if page - 1 < self.workspaces.count { self.onWorkspaceSelected?(self.workspaces[page - 1].id) }
        }

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.setAccessibilityLabel("New Workspace")
        addButton.toolTip = "New Workspace (⌘N)"
        addSubview(addButton)
        addHint.translatesAutoresizingMaskIntoConstraints = false
        addHint.font = StowTheme.Font.keycap
        addHint.isHidden = true
        addSubview(addHint)

        addSubview(workspaceButton)
        addSubview(dotsView)

        NSLayoutConstraint.activate([
            workspaceButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspaceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            workspaceButton.heightAnchor.constraint(equalToConstant: 26),
            workspaceButton.trailingAnchor.constraint(lessThanOrEqualTo: dotsView.leadingAnchor, constant: -8),

            dotsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotsView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
            addHint.centerXAnchor.constraint(equalTo: addButton.centerXAnchor),
            addHint.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: -2),
            dotsView.heightAnchor.constraint(equalToConstant: 20),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        workspaceButton.colors = colors
        dotsView.colors = colors
        addButton.contentTintColor = colors.inkPrimary
        addHint.textColor = colors.inkSecondary
        dotsView.needsDisplay = true
    }

    private func updateTitle() {
        if isSettingsSelected {
            workspaceButton.configure(name: "Settings", dotColor: nil, symbol: "gearshape.fill")
        } else if let ws = workspaces.first(where: { $0.id == selectedWorkspaceId }) {
            workspaceButton.configure(name: ws.name, dotColor: ws.colorId.color, symbol: nil)
        }
        let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }).map { $0 + 1 }
        workspaceButton.setAccessibilityLabel(isSettingsSelected
            ? "Settings, workspace menu"
            : "Workspace \(workspaceButton.name)\(index.map { ", \($0) of \(workspaces.count)" } ?? ""), menu")
        applyColors()
    }

    private func rebuildDots() {
        dotsView.pageCount = workspaces.count + 1
        updateDots()
    }

    private func updateDots() {
        if let visualPageOffset {
            dotsView.position = visualPageOffset
        } else if isSettingsSelected {
            dotsView.position = 0
        } else if let idx = workspaces.firstIndex(where: { $0.id == selectedWorkspaceId }) {
            dotsView.position = CGFloat(idx + 1)
        }
    }

    // MARK: - Menu

    @objc private func showWorkspaceMenu() {
        let entries = workspaces.map { WorkspaceSwitcherMenu.Entry(id: $0.id, name: $0.name, colorId: $0.colorId) }
        let menu = WorkspaceSwitcherMenu.make(workspaces: entries, current: isSettingsSelected ? nil : selectedWorkspaceId) { [weak self] id in
            self?.onWorkspaceSelected?(id)
        }
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Workspace…", action: #selector(addTapped), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)
        if !isSettingsSelected, let id = selectedWorkspaceId {
            let rename = NSMenuItem(title: "Rename Workspace…", action: #selector(menuRename), keyEquivalent: "")
            rename.target = self
            rename.representedObject = id
            menu.addItem(rename)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: workspaceButton.bounds.height + 4), in: workspaceButton)
    }

    /// Forwards to the shared WorkspaceDot until this view is retired.
    static func dotImage(color: NSColor, diameter: CGFloat = 10) -> NSImage {
        WorkspaceDot.image(color: color, diameter: diameter)
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        beginInlineRename(workspaceId: id)
    }

    @objc private func addTapped() { onAddWorkspace?() }
    @objc private func settingsTapped() { onSettingsSelected?() }

    // MARK: - Inline rename

    func beginInlineRename(workspaceId: UUID) {
        guard workspaceId == selectedWorkspaceId, !isSettingsSelected else { return }
        renamingWorkspaceId = workspaceId
        workspaceButton.beginRename(onCommit: { [weak self] newName in
            guard let self, let id = self.renamingWorkspaceId else { return }
            self.renamingWorkspaceId = nil
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self.onWorkspaceRename?(id, trimmed) }
        }, onCancel: { [weak self] in
            self?.renamingWorkspaceId = nil
        })
    }

    func cancelInlineRename() {
        workspaceButton.cancelRename()
        renamingWorkspaceId = nil
    }
}

/// Dot, name and up/down chevron. Click opens the menu; double-click renames.
private final class WorkspaceMenuButton: BaseControl {
    private let dotView = NSImageView()
    private let titleField = InlineEditableTextField()
    private let chevron = NSImageView()
    private(set) var name = ""
    var onRightClick: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var colors: StowTheme.Colors? { didSet { updateAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = StowTheme.List.rowRadius
        setAccessibilityRole(.popUpButton)
        for v in [dotView, titleField, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        titleField.font = StowTheme.Font.title
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 12),
            dotView.heightAnchor.constraint(equalToConstant: 12),
            titleField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            chevron.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, dotColor: NSColor?, symbol: String?) {
        self.name = name
        if !titleField.isEditing { titleField.text = name }
        if let dotColor {
            dotView.image = WorkspaceBarView.dotImage(color: dotColor, diameter: 12)
            dotView.contentTintColor = nil
        } else if let symbol {
            dotView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            dotView.contentTintColor = colors?.inkPrimary
        }
        invalidateIntrinsicContentSize()
        updateAppearance()
    }

    func beginRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        titleField.beginInlineRename(onCommit: onCommit, onCancel: onCancel)
    }

    func cancelRename() {
        titleField.cancelInlineRename()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        if titleField.isEditing { return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }

    override func handleHoverStateChanged() { updateAppearance() }
    override func handlePressedStateChanged() { updateAppearance() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let colors else { return }
        let fill: NSColor = isPressed ? colors.multiSelected : (isHovered ? colors.hover : .clear)
        layer?.backgroundColor = resolvedCGColor(fill)
        titleField.textColor = colors.inkPrimary
        chevron.contentTintColor = colors.inkSecondary
        if dotView.image?.isTemplate == true { dotView.contentTintColor = colors.inkPrimary }
    }
}

/// One dot per page (Settings first, as a small gear), with a pill that follows the
/// swipe offset. Clicking a dot jumps to that page.
private final class PageDotsView: NSView {
    var pageCount = 1 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Draws each workspace's ⌘ number (1–9) instead of its dot.
    var showsNumbers = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var position: CGFloat = 1 { didSet { needsDisplay = true } }
    var colors: StowTheme.Colors?
    var onSelectPage: ((Int) -> Void)?

    private let dot: CGFloat = StowTheme.Chrome.pageIndicatorDot
    private let gap: CGFloat = 5
    /// Beyond this many pages the dots collapse to a "3 / 14" counter.
    private let maxDots = 12
    private var showsCounter: Bool { pageCount > maxDots }

    private let numberSlot: CGFloat = 13

    override var intrinsicContentSize: NSSize {
        if showsNumbers && !showsCounter { return NSSize(width: CGFloat(min(pageCount, 10)) * numberSlot, height: 20) }
        if showsCounter { return NSSize(width: 44, height: 20) }
        return NSSize(width: CGFloat(pageCount) * dot + CGFloat(max(0, pageCount - 1)) * gap + dot, height: 20)
    }

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .valueIndicator }
    override func accessibilityLabel() -> String? {
        let page = Int(position.rounded())
        return page == 0 ? "Settings page" : "Workspace \(page) of \(pageCount - 1)"
    }

    private func center(of page: Int) -> CGFloat {
        dot / 2 + CGFloat(page) * (dot + gap) + dot / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        let midY = bounds.midY
        if showsCounter {
            let page = Int(position.rounded())
            let text = page == 0 ? "Settings" : "\(page) / \(pageCount - 1)"
            let attrs: [NSAttributedString.Key: Any] = [.font: StowTheme.Font.meta, .foregroundColor: colors.inkSecondary]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.maxX - size.width, y: midY - size.height / 2), withAttributes: attrs)
            return
        }
        if showsNumbers {
            // ⌘, for Settings, then ⌘1–⌘9 for the first nine workspaces.
            let current = Int(position.rounded())
            for page in 0..<min(pageCount, 10) {
                let text = page == 0 ? "," : "\(page)"
                let isCurrent = page == current
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isCurrent ? StowTheme.Font.title : StowTheme.Font.meta,
                    .foregroundColor: isCurrent ? colors.inkPrimary : colors.inkSecondary,
                ]
                let size = text.size(withAttributes: attrs)
                let cx = numberSlot / 2 + CGFloat(page) * numberSlot
                text.draw(at: NSPoint(x: cx - size.width / 2, y: midY - size.height / 2), withAttributes: attrs)
            }
            return
        }
        colors.guide.setFill()
        for page in 0..<pageCount {
            let x = center(of: page)
            if page == 0 {
                let r = NSRect(x: x - dot / 2, y: midY - dot / 2, width: dot, height: dot)
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            } else {
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: midY - dot / 2, width: dot, height: dot)).fill()
            }
        }
        let clamped = min(max(position, 0), CGFloat(pageCount - 1))
        let x = dot / 2 + clamped * (dot + gap) + dot / 2
        colors.inkPrimary.setFill()
        let pill = NSRect(x: x - dot / 2 - 1, y: midY - dot / 2 - 1, width: dot + 2, height: dot + 2)
        NSBezierPath(ovalIn: pill).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard !showsCounter, pageCount > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let page = Int(((x - dot / 2) / (dot + gap)).rounded(.down))
        onSelectPage?(min(max(page, 0), pageCount - 1))
    }
}
