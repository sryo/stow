import AppKit

/// The app sheet (Where Stow lives, Open at login, Keyboard, Appearance, iCloud, Import)
/// in a flyout hung off a gear: the Tabline's, away from the edge the strip rides, and the
/// rail's, beside the window. All shortcuts is pushed beside it.
///
/// The sheet's panel can take the keyboard (the shortcut recorders need it) without
/// activating Stow, so the browser stays the app in front.
@MainActor
final class AppSheetFlyout {
    enum FlyoutId: Hashable { case sheet, allShortcuts }

    let flyouts = FlyoutController()
    let sheet: AppSheetView
    let sheetPanel = FlyoutPanel(takesKey: true)
    private let shortcutsPanel = FlyoutPanel(takesKey: true)
    private var lastShow: (anchor: NSRect, edge: FlyoutPanel.Edge, topInset: CGFloat, parent: NSWindow)?
    private weak var shortcutsAnchor: NSView?

    /// After the sheet closes, by any path.
    var onClose: (() -> Void)?

    var isOpen: Bool { flyouts.isOpen(id: FlyoutId.sheet) }
    var panels: [FlyoutPanel] { flyouts.panels }

    init(preferences: AppPreferences = .shared) {
        sheet = AppSheetView(style: .flyout, preferences: preferences)
        flyouts.onOutsideClick = { [weak self] in self?.close() }
        sheet.onHeightChange = { [weak self] in
            guard let self, self.isOpen else { return }
            self.reposition()
        }
        sheet.onImport = { [weak self] in
            self?.close()
            NotificationCenter.default.post(name: .stowShowImport, object: nil)
        }
        sheet.onShowAllShortcuts = { [weak self] link in
            guard let self else { return }
            self.shortcutsAnchor = link
            self.flyouts.toggle(id: FlyoutId.allShortcuts) { self.showAllShortcuts() }
        }
    }

    /// Opens the sheet from the gear at `anchor` (screen coordinates), or closes it when
    /// it's open. `colorId` is the workspace on show, for the page-color previews.
    func toggle(anchor: NSRect, edge: FlyoutPanel.Edge, topInset: CGFloat = 0, parent: NSWindow,
                colorId: WorkspaceColorId = .defaultColor()) {
        if isOpen { return close() }
        sheet.previewColor = colorId
        sheet.refresh()
        lastShow = (anchor, edge, topInset, parent)
        reposition()
        sheet.footer.updateTimer()
    }

    /// The Tabline's gear: the sheet opens away from the edge the strip rides.
    func toggle(anchor: NSRect, edge: TablineEdge, parent: NSWindow, colorId: WorkspaceColorId = .defaultColor()) {
        toggle(anchor: anchor, edge: TablineController.flyoutEdge(for: edge), parent: parent, colorId: colorId)
    }

    func close() {
        guard flyouts.isOpen else { return }
        flyouts.closeAll()
        sheet.footer.updateTimer()
        lastShow = nil
        onClose?()
    }

    private func reposition() {
        guard let show = lastShow else { return }
        sheetPanel.level = show.parent.level
        let height = sheet.preferredHeight
        sheet.frame.size.height = height
        flyouts.show(sheetPanel, id: FlyoutId.sheet, content: sheet, size: NSSize(width: AppSheetView.width, height: height),
                     anchor: show.anchor, edge: show.edge, topInset: show.topInset, parent: show.parent,
                     onEscape: { [weak self] in self?.close() })
        if flyouts.isOpen(id: FlyoutId.allShortcuts) { showAllShortcuts() }
    }

    private func showAllShortcuts() {
        guard isOpen, let link = shortcutsAnchor, let window = link.window else { return }
        let anchor = window.convertToScreen(link.convert(link.bounds, to: nil))
        let shown = flyouts.isOpen(id: FlyoutId.allShortcuts) ? shortcutsPanel.content as? AllShortcutsView : nil
        let list = shown ?? AllShortcutsView()
        shortcutsPanel.level = sheetPanel.level
        flyouts.push(shortcutsPanel, id: FlyoutId.allShortcuts, content: list, size: list.preferredSize,
                     anchor: anchor, topInset: 24)
    }
}
