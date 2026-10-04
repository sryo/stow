import AppKit

/// Color Strip tabs: every workspace is a segment of one row, tinted with its own color.
/// The current workspace is an ink pill with its full name; the rest compress per
/// `WorkspaceStripLayout`. During a swipe the strip blends between page layouts.
///
/// Page indices match the pager: 0 is Settings, workspaces start at 1, N+1 is "+".
@MainActor
final class WorkspaceStripView: NSView {
    struct WorkspaceItem: Equatable {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
    }

    var workspaces: [WorkspaceItem] = [] {
        didSet { if workspaces != oldValue { itemsChanged() } }
    }
    var selectedWorkspaceId: UUID? { didSet { needsLayout = true } }
    var isSettingsSelected = false { didSet { needsLayout = true } }
    /// The palette of the page being shown (drives pill ink and borders).
    var workspaceColor: WorkspaceColorId = .defaultColor() {
        didSet { needsLayout = true; updateColors() }
    }
    var visualPageOffset: CGFloat? {
        didSet { needsLayout = true }
    }
    var showsShortcutHints = false { didSet { updateColors() } }

    var onWorkspaceSelected: ((UUID) -> Void)?
    var onWorkspaceRightClick: ((UUID, NSPoint) -> Void)?
    var onWorkspaceRename: ((UUID, String) -> Void)?
    var onWorkspaceReorder: ((UUID, Int) -> Void)?
    /// An item (node id) dropped on a workspace's tab (workspace id).
    var onDropNode: ((UUID, UUID) -> Void)?

    private var items: [WorkspaceStripLayout.Item] = []
    private var metrics: [WorkspaceStripLayout.Metrics] = []
    private var memory: WorkspaceStripLayout.Memory?
    private var tabViews: [UUID: StripTabView] = [:]
    private let overflowButton = NSButton()
    private var overflowIds: [UUID] = []
    private var renameField: NSTextField?
    private var renamingId: UUID?
    private var drag: (id: UUID, startX: CGFloat, originX: CGFloat, moved: Bool)?

    var isInlineRenaming: Bool { renamingId != nil }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overflowButton.isBordered = false
        overflowButton.wantsLayer = true
        overflowButton.layer?.cornerRadius = WorkspaceStripLayout.K.radius
        overflowButton.layer?.borderWidth = 1
        overflowButton.font = StowTheme.Font.control
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.setAccessibilityLabel("More workspaces")
        addSubview(overflowButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Workspaces")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Model

    private func itemsChanged() {
        var newItems = workspaces.map { WorkspaceStripLayout.Item(id: $0.id, name: $0.name) }
        WorkspaceStripLayout.assignMonograms(&newItems)
        items = newItems
        metrics = WorkspaceStripLayout.metrics(for: items)
        let ids = Set(workspaces.map(\.id))
        for (id, view) in tabViews where !ids.contains(id) { view.removeFromSuperview(); tabViews[id] = nil }
        for ws in workspaces where tabViews[ws.id] == nil {
            let tab = StripTabView()
            tab.onMouseDown = { [weak self] event in self?.tabMouseDown(ws.id, event) }
            tab.onRightClick = { [weak self] point in self?.onWorkspaceRightClick?(ws.id, point) }
            addSubview(tab, positioned: .below, relativeTo: overflowButton)
            tabViews[ws.id] = tab
        }
        memory = nil
        needsLayout = true
        updateColors()
    }

    private var currentPage: Int {
        if isSettingsSelected { return 0 }
        if let id = selectedWorkspaceId, let i = workspaces.firstIndex(where: { $0.id == id }) { return i + 1 }
        return 1
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard !items.isEmpty, bounds.width > 20 else { return }
        let width = bounds.width
        let layout: WorkspaceStripLayout
        if let offset = visualPageOffset {
            let n = items.count
            let clamped = min(max(offset, 0), CGFloat(n + 1))
            let lower = Int(clamped.rounded(.down)), upper = min(lower + 1, n + 1)
            let a = WorkspaceStripLayout.rest(width: width, items: items, metrics: metrics, page: lower, previous: memory)
            let b = WorkspaceStripLayout.rest(width: width, items: items, metrics: metrics, page: upper, previous: memory)
            layout = WorkspaceStripLayout.lerp(a, b, clamped - CGFloat(lower))
        } else {
            let editingWidth = renamingId != nil ? renameEditingWidth() : nil
            layout = WorkspaceStripLayout.rest(width: width, items: items, metrics: metrics, page: currentPage, previous: memory, editingWidth: editingWidth)
            memory = layout.memory
        }
        apply(layout)
    }

    private func apply(_ layout: WorkspaceStripLayout) {
        let height = WorkspaceStripLayout.K.tabHeight
        let y = (bounds.height - height) / 2
        let page = colors
        for (i, tab) in layout.tabs.enumerated() {
            guard let view = tabViews[tab.id], i < workspaces.count else { continue }
            let ws = workspaces[i]
            if drag?.id != tab.id {
                view.frame = NSRect(x: tab.x, y: y, width: max(0, tab.width), height: height)
            }
            view.isHidden = tab.width < 0.5 || tab.alpha < 0.01
            view.alphaValue = tab.alpha
            view.configure(name: ws.name, monogram: items[i].monogram, own: StowTheme.colors(for: ws.colorId),
                           page: page, selection: tab.selection, nameAlpha: tab.nameAlpha, monogramAlpha: tab.monogramAlpha,
                           leftRadius: tab.leftRadius, rightRadius: tab.rightRadius,
                           hint: showsShortcutHints && i < 9 ? "\(i + 1)" : nil, editing: renamingId == ws.id)
            view.toolTip = "\(ws.name)\(i < 9 ? "  ⌘\(i + 1)" : "")"
            view.setAccessibilityLabel("\(ws.name), workspace \(i + 1) of \(workspaces.count)")
            view.setAccessibilityValue(tab.selection > 0.5 ? 1 : 0)
        }
        let o = layout.overflow
        overflowButton.isHidden = o.width < 0.5
        overflowButton.frame = NSRect(x: o.x, y: y, width: o.width, height: height)
        overflowButton.title = "+\(o.count)"
        overflowButton.contentTintColor = page.inkPrimary
        overflowButton.attributedTitle = NSAttributedString(string: "+\(o.count)", attributes: [.foregroundColor: page.inkPrimary, .font: StowTheme.Font.control])
        overflowButton.layer?.borderColor = resolvedCGColor(page.guide)
        overflowIds = o.hiddenIds
        if let field = renameField, let id = renamingId, let view = tabViews[id] {
            field.frame = view.frame.insetBy(dx: 6, dy: 3)
        }
    }

    private var colors: StowTheme.Colors {
        StowTheme.colors(for: workspaceColor, tint: StowTheme.displayTint)
    }

    private func updateColors() {
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // MARK: - Interaction

    private func tabMouseDown(_ id: UUID, _ event: NSEvent) {
        guard renamingId == nil else { return }
        if event.clickCount == 2 {
            beginInlineRename(workspaceId: id)
            return
        }
        guard let view = tabViews[id] else { return }
        drag = (id, convert(event.locationInWindow, from: nil).x, view.frame.minX, false)
        trackDrag()
    }

    /// Click selects; a horizontal drag reorders.
    private func trackDrag() {
        guard let window else { return }
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard var d = drag, let view = tabViews[d.id] else { break }
            let x = convert(event.locationInWindow, from: nil).x
            if event.type == .leftMouseDragged {
                if abs(x - d.startX) > 4 { d.moved = true }
                drag = d
                if d.moved {
                    view.frame.origin.x = d.originX + (x - d.startX)
                    view.layer?.zPosition = 10
                }
            } else {
                drag = nil
                view.layer?.zPosition = 0
                if d.moved {
                    let center = view.frame.midX
                    let others = workspaces.enumerated().filter { $0.element.id != d.id }
                    let target = others.filter { (tabViews[$0.element.id]?.frame.midX ?? 0) < center }.count
                    onWorkspaceReorder?(d.id, target)
                    needsLayout = true
                } else {
                    onWorkspaceSelected?(d.id)
                }
                break
            }
        }
    }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        for id in overflowIds {
            guard let ws = workspaces.first(where: { $0.id == id }), let i = workspaces.firstIndex(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(title: ws.name, action: #selector(overflowPicked(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.representedObject = id
            item.image = WorkspaceBarView.dotImage(color: StowTheme.colors(for: ws.colorId).light.surface.platformColor)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 4), in: overflowButton)
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { onWorkspaceSelected?(id) }
    }

    // MARK: - Rename

    private func renameEditingWidth() -> CGFloat {
        let text = renameField?.stringValue ?? ""
        return WorkspaceStripLayout.textWidth(text.isEmpty ? "W" : text, weight: .semibold) + 40
    }

    func beginInlineRename(workspaceId: UUID) {
        guard let ws = workspaces.first(where: { $0.id == workspaceId }) else { return }
        if selectedWorkspaceId != workspaceId { onWorkspaceSelected?(workspaceId) }
        renamingId = workspaceId
        let field = NSTextField(string: ws.name)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = StowTheme.Font.title
        field.textColor = colors.surface
        field.delegate = self
        field.target = self
        field.action = #selector(commitRename)
        addSubview(field)
        renameField = field
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func commitRename() {
        guard let id = renamingId, let field = renameField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        if !name.isEmpty { onWorkspaceRename?(id, name) }
    }

    func cancelInlineRename() { endRename() }

    /// Clears `renamingId` before the field leaves the window: removing a focused field
    /// ends its editing, and `controlTextDidEndEditing` would otherwise commit it.
    private func endRename() {
        let field = renameField
        renamingId = nil
        renameField = nil
        if let field, window?.firstResponder === field.currentEditor() {
            window?.makeFirstResponder(nil)
        }
        field?.removeFromSuperview()
        needsLayout = true
    }
}

extension WorkspaceStripView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { needsLayout = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if renamingId != nil { commitRename() }
    }
}

/// One segment: its own workspace color at rest, the page's ink pill when selected.
private final class StripTabView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let monoLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private var isHovered = false
    private var tracking: NSTrackingArea?
    private var last: (own: StowTheme.Colors, page: StowTheme.Colors, selection: CGFloat)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        for label in [nameLabel, monoLabel, hintLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        monoLabel.alignment = .center
        monoLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hintLabel.font = StowTheme.Font.keycap
        dot.cornerRadius = WorkspaceStripLayout.K.dot / 2
        layer?.addSublayer(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, monogram: String, own: StowTheme.Colors, page: StowTheme.Colors, selection s: CGFloat,
                   nameAlpha: CGFloat, monogramAlpha: CGFloat, leftRadius: CGFloat, rightRadius: CGFloat,
                   hint: String?, editing: Bool) {
        last = (own, page, s)
        nameLabel.stringValue = name
        monoLabel.stringValue = monogram
        nameLabel.font = .systemFont(ofSize: 13, weight: s > 0.5 ? .semibold : .medium)
        nameLabel.alphaValue = editing ? 0 : nameAlpha
        monoLabel.alphaValue = monogramAlpha
        hintLabel.stringValue = hint.map { "⌘\($0)" } ?? ""
        hintLabel.isHidden = hint == nil || nameAlpha < 0.5
        dot.opacity = Float(s)
        layer?.maskedCorners = []
        layer?.cornerRadius = max(leftRadius, rightRadius)
        var corners: CACornerMask = []
        if leftRadius > 0.5 { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if rightRadius > 0.5 { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        layer?.maskedCorners = corners
        paint()
        needsLayout = true
    }

    private func paint() {
        guard let (own, page, s) = last else { return }
        let rest = isHovered && s < 0.5 ? own.hover : own.surface
        let fill = blend(resolved(rest), resolved(page.inkPrimary), s)
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = blend(resolved(page.guide), resolved(page.inkPrimary), s).cgColor
        let ink = blend(resolved(own.inkPrimary), resolved(page.surface), s)
        nameLabel.textColor = ink
        monoLabel.textColor = resolved(own.inkPrimary)
        hintLabel.textColor = blend(resolved(own.inkSecondary), resolved(page.surface), s)
        dot.backgroundColor = resolved(own.surface).cgColor
    }

    private func resolved(_ color: NSColor) -> NSColor {
        var out = color
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        a.blended(withFraction: max(0, min(1, t)), of: b) ?? a
    }

    override func layout() {
        super.layout()
        let K = WorkspaceStripLayout.K.self
        let s = last?.selection ?? 0
        let left = K.unselectedPadding + (K.selectedPaddingLeft + K.dot + K.dotGap - K.unselectedPadding) * s
        let right = K.unselectedPadding + (K.selectedPaddingRight - K.unselectedPadding) * s
        let hintWidth: CGFloat = hintLabel.isHidden ? 0 : hintLabel.intrinsicContentSize.width + 4
        let labelHeight = nameLabel.intrinsicContentSize.height
        nameLabel.frame = NSRect(x: left - 2, y: (bounds.height - labelHeight) / 2, width: max(0, bounds.width - left - right - hintWidth + 4), height: labelHeight)
        hintLabel.frame = NSRect(x: bounds.width - right - hintWidth + 4, y: (bounds.height - labelHeight) / 2 + 1, width: hintWidth, height: labelHeight)
        monoLabel.frame = NSRect(x: 0, y: (bounds.height - labelHeight) / 2, width: bounds.width, height: labelHeight)
        dot.frame = CGRect(x: K.selectedPaddingLeft - 1, y: (bounds.height - K.dot) / 2, width: K.dot, height: K.dot)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; paint() }
    override func mouseExited(with event: NSEvent) { isHovered = false; paint() }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event.locationInWindow) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); paint() }
}
