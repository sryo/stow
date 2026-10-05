import AppKit
import StowShared

/// A list inside a FlyoutPanel, in the rail flyout's style: a section header with a quiet
/// count, rows of glyph · title · trailing (an open ●, a check, a due date), and optional
/// footer buttons. ↑/↓ move, Return picks, typing jumps to a title, → opens a subfolder,
/// ⌥Return runs the Open all button, when the list has one. Links and snippets drag out of it.
@MainActor
final class FlyoutListView: NSView {
    struct FooterButton {
        var title: String
        var style: FlyoutButton.Style = .plain
        /// ⌥Return runs this button.
        var isOpenAll = false
        var action: () -> Void

        /// A folder list's "Open all", the button ⌥Return runs.
        static func openAll(_ action: @escaping () -> Void) -> FooterButton {
            FooterButton(title: "Open all  ⌥↩", style: .primary, isOpenAll: true, action: action)
        }
    }

    enum Metrics {
        static let width: CGFloat = 244
        static let padding: CGFloat = 12
        static let headerHeight: CGFloat = 16
        static let headerGap: CGFloat = 6
        static let rowHeight: CGFloat = 28
        static let sectionTitleHeight: CGFloat = 24
        static let separatorHeight: CGFloat = 17
        static let footerHeight: CGFloat = 24
        static let maxRowsHeight: CGFloat = 420
        static let glyph: CGFloat = 18
        /// From the card's top to the first row's middle: where the arrow points.
        static let firstRowMidY: CGFloat = padding + headerHeight + headerGap + rowHeight / 2
    }

    /// A row was picked (click, Return, VoiceOver press), with its view for anchoring.
    var onActivate: ((FlyoutListRow, NSView) -> Void)?
    /// The row's trailing button was clicked ("Edit", a due date).
    var onSecondary: ((FlyoutListRow, NSView) -> Void)?
    /// A row was right-clicked.
    var onRowMenu: ((FlyoutListRow, NSView) -> Void)?

    private let header: NSTextField
    private let detail: NSTextField
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let separator = NSView()
    private var footerButtons: [FlyoutButton] = []
    private var footerActions: [() -> Void] = []
    private var openAllAction: (() -> Void)?
    private var sectionLabels: [NSTextField] = []
    private(set) var sections: [FlyoutListSection]
    private(set) var rowViews: [FlyoutListRowView] = []
    private var selected: Int? { didSet { updateSelection() } }
    private var typeSelect = ""
    private var typeSelectTime = Date.distantPast

    init(title: String, detail: String? = nil, sections: [FlyoutListSection], footer: [FooterButton] = []) {
        self.sections = sections
        header = FlyoutLabel.section(title)
        self.detail = FlyoutLabel.text(detail ?? "", size: 11, color: FlyoutColors.inkSecondary)
        super.init(frame: .zero)
        self.detail.alignment = .right
        addSubview(header)
        addSubview(self.detail)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        addSubview(scrollView)

        separator.wantsLayer = true
        if !footer.isEmpty { addSubview(separator) }
        for button in footer {
            let b = FlyoutButton(button.title, style: button.style)
            b.target = self
            b.action = #selector(footerTapped(_:))
            footerButtons.append(b)
            footerActions.append(button.action)
            if button.isOpenAll, openAllAction == nil { openAllAction = button.action }
            addSubview(b)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(title)
        rebuildRows()
    }

    convenience init(title: String, detail: String? = nil, rows: [FlyoutListRow], footer: [FooterButton] = []) {
        self.init(title: title, detail: detail, sections: [FlyoutListSection(title: nil, rows: rows)], footer: footer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var rows: [FlyoutListRow] { rowViews.map(\.row) }

    // MARK: Content

    /// Replaces the rows, keeping the selection on the same row id when it's still there.
    func update(title: String? = nil, detail: String? = nil, sections: [FlyoutListSection]) {
        let selectedId = selected.map { rowViews[$0].row.id }
        if let title { header.attributedStringValue = FlyoutLabel.section(title).attributedStringValue }
        if let detail { self.detail.stringValue = detail }
        self.sections = sections
        rebuildRows()
        selected = selectedId.flatMap { id in rowViews.firstIndex { $0.row.id == id } }
    }

    func update(rows: [FlyoutListRow]) {
        update(sections: [FlyoutListSection(title: nil, rows: rows)])
    }

    /// Flips one row's check without a rebuild: a toggled task, a copied snippet.
    func setChecked(_ checked: Bool, rowId: String) {
        guard let view = rowViews.first(where: { $0.row.id == rowId }) else { return }
        var row = view.row
        row.isChecked = checked
        if case .task = row.glyph { row.glyph = .task(done: checked) }
        view.row = row
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        sectionLabels.forEach { $0.removeFromSuperview() }
        rowViews = []
        sectionLabels = []
        var y: CGFloat = 0
        for (s, section) in sections.enumerated() {
            if s > 0 { y += 6 }
            if let title = section.title {
                let label = FlyoutLabel.section(title)
                label.frame = NSRect(x: 6, y: y + 8, width: Metrics.width - Metrics.padding * 2 - 12, height: 14)
                document.addSubview(label)
                sectionLabels.append(label)
                y += Metrics.sectionTitleHeight
            }
            for row in section.rows {
                let view = FlyoutListRowView(row: row)
                view.frame = NSRect(x: 0, y: y, width: Metrics.width - Metrics.padding * 2, height: Metrics.rowHeight)
                view.onHover = { [weak self, weak view] in
                    guard let self, let view, let i = self.rowViews.firstIndex(where: { $0 === view }) else { return }
                    self.selected = i
                }
                view.onClick = { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.onActivate?(view.row, view)
                }
                view.onSecondary = { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.onSecondary?(view.row, view)
                }
                view.onRightClick = { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.onRowMenu?(view.row, view)
                }
                document.addSubview(view)
                rowViews.append(view)
                y += Metrics.rowHeight
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: Metrics.width - Metrics.padding * 2, height: y)
        needsLayout = true
    }

    private var rowsHeight: CGFloat { min(document.frame.height, Metrics.maxRowsHeight) }

    var preferredSize: NSSize {
        var h = Metrics.padding + Metrics.headerHeight + Metrics.headerGap + rowsHeight + Metrics.padding
        if !footerButtons.isEmpty {
            let rows = CGFloat(footerStacks ? footerButtons.count : 1)
            h += Metrics.separatorHeight + rows * Metrics.footerHeight + (rows - 1) * 6
        }
        return NSSize(width: Metrics.width, height: ceil(h))
    }

    /// Footer buttons that don't fit side by side ("Edit workspace…", "New workspace…")
    /// take a full-width line each.
    private var footerStacks: Bool {
        let inner = Metrics.width - Metrics.padding * 2
        return footerButtons.map(\.fittingWidth).reduce(0, +) + CGFloat(max(0, footerButtons.count - 1)) * 6 > inner
    }

    override func layout() {
        super.layout()
        let p = Metrics.padding
        let inner = bounds.width - p * 2
        let detailWidth = min(ceil(detail.intrinsicContentSize.width) + 4, inner * 0.5)
        header.frame = NSRect(x: p + 2, y: p + 1, width: inner - detailWidth - 12, height: 14)
        detail.frame = NSRect(x: bounds.width - p - 2 - detailWidth, y: p, width: detailWidth, height: 15)
        let top = p + Metrics.headerHeight + Metrics.headerGap
        scrollView.frame = NSRect(x: p, y: top, width: inner, height: rowsHeight)
        document.frame.size.width = inner
        var y = scrollView.frame.maxY
        if !footerButtons.isEmpty {
            separator.frame = NSRect(x: p, y: y + 8, width: inner, height: 0.5)
            y += Metrics.separatorHeight
            var x = p
            let stacks = footerStacks
            for b in footerButtons {
                if stacks {
                    b.frame = NSRect(x: p, y: y, width: inner, height: Metrics.footerHeight)
                    y += Metrics.footerHeight + 6
                } else {
                    let w = b.fittingWidth
                    b.frame = NSRect(x: x, y: y, width: w, height: Metrics.footerHeight)
                    x += w + 6
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separator.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        separator.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
    }

    // MARK: Selection and keys

    private func updateSelection() {
        for (i, view) in rowViews.enumerated() { view.isSelected = i == selected }
        if let selected { document.scrollToVisible(rowViews[selected].frame) }
    }

    /// Selects the first row, for keyboard use right after the flyout opens.
    func selectFirstRow() {
        selected = rowViews.isEmpty ? nil : 0
    }

    var selectedRow: FlyoutListRow? { selected.map { rowViews[$0].row } }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveDown(_ sender: Any?) {
        guard !rowViews.isEmpty else { return }
        selected = min((selected ?? -1) + 1, rowViews.count - 1)
    }

    override func moveUp(_ sender: Any?) {
        guard !rowViews.isEmpty else { return }
        selected = max((selected ?? rowViews.count) - 1, 0)
    }

    override func moveToBeginningOfDocument(_ sender: Any?) { if !rowViews.isEmpty { selected = 0 } }
    override func moveToEndOfDocument(_ sender: Any?) { if !rowViews.isEmpty { selected = rowViews.count - 1 } }

    override func insertNewline(_ sender: Any?) { activateSelected() }

    /// ⌥Return: Open all, as everywhere in Stow. Lists without it ignore the key.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        openAllAction?()
    }

    override func moveRight(_ sender: Any?) {
        guard let selected, case .pushFolder = rowViews[selected].row.action else { return }
        activateSelected()
    }

    override func moveLeft(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    override func insertText(_ insertString: Any) {
        guard let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string else { return }
        if text == " " { activateSelected(); return }
        let now = Date()
        typeSelect = now.timeIntervalSince(typeSelectTime) > 1 ? text : typeSelect + text
        typeSelectTime = now
        if let i = FlyoutListView.typeSelectIndex(typeSelect, in: rowViews.map(\.row.title), from: selected) {
            selected = i
        }
    }

    /// The first title starting with `prefix`, ignoring case and accents, searching from
    /// the selection onward and wrapping.
    static func typeSelectIndex(_ prefix: String, in titles: [String], from start: Int?) -> Int? {
        guard !titles.isEmpty, !prefix.isEmpty else { return nil }
        let begin = start ?? 0
        let order = Array(begin..<titles.count) + Array(0..<begin)
        return order.first { i in
            titles[i].range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func activateSelected() {
        guard let selected else { return }
        let view = rowViews[selected]
        onActivate?(view.row, view)
    }

    override func doCommand(by selector: Selector) {
        // Esc and anything else the list doesn't use go up to the panel.
        if selector == #selector(cancelOperation(_:)) {
            window?.cancelOperation(nil)
            return
        }
        super.doCommand(by: selector)
    }

    @objc private func footerTapped(_ sender: FlyoutButton) {
        guard let i = footerButtons.firstIndex(where: { $0 === sender }) else { return }
        footerActions[i]()
    }

    // MARK: Testing

    func performFooterAction(at index: Int) { footerActions[index]() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

/// One drawn row. Hover selects it, a click picks it, a click on a trailing button runs
/// the row's secondary action, and a drag past 4pt carries its link or snippet out.
@MainActor
final class FlyoutListRowView: NSView, NSDraggingSource {
    var row: FlyoutListRow {
        didSet { needsDisplay = true; updateAccessibility() }
    }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onSecondary: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var trailingRect: NSRect = .zero

    init(row: FlyoutListRow) {
        self.row = row
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateAccessibility() {
        var parts = [row.title]
        if row.isOpen { parts.append("open in browser") }
        if case .task = row.glyph { parts.append(row.isChecked ? "done" : "not done") } else if row.isChecked { parts.append("selected") }
        if let trailing = row.trailing, trailing != "done" { parts.append(trailing) }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        onRightClick?()
        return true
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        // The Tabline's flyouts float over a browser, so hover works while Stow is inactive.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?() } }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let item = pasteboardItem() else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if row.secondary != nil, trailingRect.insetBy(dx: -4, dy: -4).contains(p) {
            onSecondary?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    private func pasteboardItem() -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        switch row.node {
        case .link(let link)?:
            item.setString(link.url, forType: .URL)
            item.setString(link.url, forType: .string)
        case .snippet(let snippet)?:
            item.setString(snippet.content, forType: .string)
        default:
            return nil
        }
        return item
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let m = FlyoutListView.Metrics.self
        if isSelected {
            FlyoutColors.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let glyphRect = NSRect(x: 6, y: (bounds.height - m.glyph) / 2, width: m.glyph, height: m.glyph)
        drawGlyph(in: glyphRect)

        var right = bounds.width - 6
        let trailingText = (isSelected ? row.hoverTrailing : nil) ?? row.trailing
        trailingRect = .zero
        if let trailingText, !trailingText.isEmpty {
            let color = row.isOverdue && trailingText == row.trailing ? FlyoutColors.danger : FlyoutColors.inkSecondary
            let attrs: [NSAttributedString.Key: Any] = [.font: FlyoutFonts.ui(11.5, row.secondary != nil && isSelected ? .medium : .regular),
                                                        .foregroundColor: color]
            let size = (trailingText as NSString).size(withAttributes: attrs)
            let rect = NSRect(x: right - ceil(size.width), y: (bounds.height - size.height) / 2, width: ceil(size.width), height: size.height)
            (trailingText as NSString).draw(in: rect, withAttributes: attrs)
            trailingRect = rect
            right = rect.minX - 8
        }
        if row.isChecked, !isTask {
            if let check = Self.symbol("checkmark", size: 11, weight: .semibold, color: FlyoutColors.ink) {
                let r = NSRect(x: right - check.size.width, y: (bounds.height - check.size.height) / 2,
                               width: check.size.width, height: check.size.height)
                check.draw(in: r)
                right = r.minX - 8
            }
        }
        if row.isOpen {
            let dot = NSRect(x: right - 6, y: bounds.midY - 3, width: 6, height: 6)
            SettingsColors.success.setFill()
            NSBezierPath(ovalIn: dot).fill()
            right = dot.minX - 8
        }

        let done = isTask && row.isChecked
        var attrs: [NSAttributedString.Key: Any] = [
            .font: FlyoutFonts.ui(13, .medium),
            .foregroundColor: done ? FlyoutColors.inkSecondary : FlyoutColors.ink,
        ]
        if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = style
        let title = row.title as NSString
        let h = title.size(withAttributes: attrs).height
        let x = glyphRect.maxX + 8
        title.draw(with: NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, right - x), height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private var isTask: Bool {
        if case .task = row.glyph { return true }
        return false
    }

    private func drawGlyph(in rect: NSRect) {
        switch row.glyph {
        case .site(let title, let url, let faviconPath):
            SiteGlyph.draw(title: title, url: url, faviconPath: faviconPath, in: rect)
        case .folder:
            drawTile(symbol: "folder", in: rect)
        case .snippet:
            drawTile(symbol: "chevron.left.forwardslash.chevron.right", in: rect)
        case .symbol(let name):
            drawTile(symbol: name, in: rect)
        case .task(let done):
            let name = done ? "checkmark.circle.fill" : "circle"
            if let image = Self.symbol(name, size: 14, weight: .regular, color: done ? FlyoutColors.inkSecondary : FlyoutColors.ink) {
                image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height))
            }
        case .workspace(let colorId):
            WorkspaceDot.draw(in: NSRect(x: rect.midX - 6, y: rect.midY - 6, width: 12, height: 12), color: colorId.color)
        }
    }

    private func drawTile(symbol: String, in rect: NSRect) {
        FlyoutColors.field.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        guard let image = Self.symbol(symbol, size: 10, weight: .semibold, color: FlyoutColors.inkSecondary) else { return }
        image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height))
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

// MARK: - Presenter

/// Shows FlyoutListViews through one FlyoutController: a root beside a column or below
/// an anchor, and a chained flyout pushed beside it for each nested folder. Owners handle
/// what rows do; the presenter closes the stack after any row that doesn't keep it open.
@MainActor
final class FlyoutListPresenter {
    let controller = FlyoutController()
    private let rootPanel: FlyoutPanel
    private let panelsTakeKey: Bool
    private var pushedPanels: [UUID: FlyoutPanel] = [:]
    private(set) var rootId: AnyHashable?
    private(set) var rootList: FlyoutListView?
    private var lastShow: (anchor: NSRect, edge: FlyoutPanel.Edge, topInset: CGFloat, parent: NSWindow)?
    private var takesKeyboard = true

    /// Open dots for rows in pushed folders.
    var openKeys: Set<String> = []
    /// Runs a picked row's action (not `pushFolder`, which the presenter handles), with
    /// the row view it came from.
    var onAction: ((FlyoutListRow.Action, FlyoutListRow, NSView) -> Void)?
    var onRowMenu: ((FlyoutListRow, NSView) -> Void)?
    /// A right-click on a workspace row ("More workspaces", the Tabline chip's list).
    var onWorkspaceMenu: ((UUID, NSView) -> Void)?
    /// "Open all" for a pushed folder's footer; nil leaves the footer off.
    var onOpenAll: ((Folder) -> Void)?
    /// Runs after the stack closes from a pick, Esc or an outside click.
    var onClose: (() -> Void)?

    var isOpen: Bool { controller.isOpen }
    var panels: [FlyoutPanel] { controller.panels }

    /// `takesKey: false` keeps every panel from becoming key, for lists over another app.
    init(takesKey: Bool = true) {
        panelsTakeKey = takesKey
        rootPanel = FlyoutPanel(takesKey: takesKey)
        controller.onOutsideClick = { [weak self] in self?.closeAll() }
    }

    /// Shows `list` as the root flyout, `id` naming what opened it.
    func show(_ list: FlyoutListView, id: AnyHashable, anchor: NSRect, edge: FlyoutPanel.Edge, topInset: CGFloat,
              parent: NSWindow, takeKeyboard: Bool = true) {
        wire(list)
        rootId = id
        rootList = list
        lastShow = (anchor, edge, topInset, parent)
        rootPanel.level = parent.level
        controller.show(rootPanel, id: id, content: list, size: list.preferredSize, anchor: anchor, edge: edge,
                        topInset: topInset, parent: parent, onEscape: { [weak self] in self?.closeAll() })
        takesKeyboard = takeKeyboard
        if takeKeyboard { focus(list, in: rootPanel) }
    }

    /// Updates the root's rows in place (after the model changed), resizing it to fit, and
    /// closes any pushed folders, whose contents may be gone.
    func refreshRoot(title: String? = nil, detail: String? = nil, sections: [FlyoutListSection]) {
        guard let list = rootList, let id = rootId, let show = lastShow, controller.isOpen(id: id) else { return }
        for pushed in controller.openIds.dropFirst() { controller.close(id: pushed) }
        list.update(title: title, detail: detail, sections: sections)
        controller.show(rootPanel, id: id, content: list, size: list.preferredSize, anchor: show.anchor, edge: show.edge,
                        topInset: show.topInset, parent: show.parent, onEscape: { [weak self] in self?.closeAll() })
    }

    func toggle(id: AnyHashable, open: () -> Void) {
        if controller.isOpen(id: id) { closeAll() } else { open() }
    }

    func closeAll() {
        let wasOpen = controller.isOpen
        controller.closeAll()
        rootId = nil
        rootList = nil
        pushedPanels = [:]
        if wasOpen { onClose?() }
    }

    private func focus(_ list: FlyoutListView, in panel: FlyoutPanel) {
        guard panel.canBecomeKey else { return }
        panel.makeKey()
        panel.makeFirstResponder(list)
        list.selectFirstRow()
    }

    private func wire(_ list: FlyoutListView) {
        list.onActivate = { [weak self, weak list] row, view in
            guard let self, let list else { return }
            self.activate(row, from: view, in: list)
        }
        list.onSecondary = { [weak self] row, view in
            guard let self, let action = row.secondary else { return }
            self.onAction?(action, row, view)
        }
        list.onRowMenu = { [weak self] row, view in
            if case .selectWorkspace(let id) = row.action { self?.onWorkspaceMenu?(id, view); return }
            guard row.node != nil else { return }
            self?.onRowMenu?(row, view)
        }
    }

    private func activate(_ row: FlyoutListRow, from view: NSView, in list: FlyoutListView) {
        if case .pushFolder = row.action, case .folder(let folder)? = row.node {
            push(folder, from: view)
            return
        }
        switch row.action {
        case .toggleTask: list.setChecked(!row.isChecked, rowId: row.id)
        case .copySnippet: list.setChecked(true, rowId: row.id)
        default: break
        }
        onAction?(row.action, row, view)
        if !row.keepsOpen { closeAll() }
    }

    /// Pushes `folder` beside the flyout holding `view`.
    func push(_ folder: Folder, from view: NSView) {
        guard let window = view.window else { return }
        let rows = FlyoutListModel.rows(for: folder, openKeys: openKeys)
        let footer: [FlyoutListView.FooterButton] = onOpenAll.map { openAll in
            [FlyoutListView.FooterButton.openAll { [weak self] in
                openAll(folder)
                self?.closeAll()
            }]
        } ?? []
        let list = FlyoutListView(title: folder.name, detail: "\(rows.count)", rows: rows,
                                  footer: folder.openableLinks.isEmpty ? [] : footer)
        wire(list)
        let panel = pushedPanels[folder.id] ?? FlyoutPanel(takesKey: panelsTakeKey)
        panel.level = window.level
        pushedPanels[folder.id] = panel
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        controller.push(panel, id: folder.id, content: list, size: list.preferredSize, anchor: anchor,
                        topInset: FlyoutListView.Metrics.firstRowMidY)
        if takesKeyboard { focus(list, in: panel) }
    }
}
