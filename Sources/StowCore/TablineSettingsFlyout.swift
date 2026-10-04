import AppKit

/// The Tabline's gear: the same app sheet the rail's sliders cell shows, in a flyout hung
/// off the gear. It opens away from the edge the strip rides (below on the top edge, above
/// on the bottom one), and All shortcuts is pushed beside it, as in the rail.
///
/// The sheet's panel can take the keyboard (the shortcut recorders need it) without
/// activating Stow, so the browser stays the app in front.
@MainActor
final class TablineSettingsFlyout {
    enum FlyoutId: Hashable { case sheet, allShortcuts }

    let flyouts = FlyoutController()
    let sheet: AppSheetView
    let sheetPanel = FlyoutPanel(takesKey: true)
    private let shortcutsPanel = FlyoutPanel(takesKey: true)
    private var lastShow: (anchor: NSRect, edge: TablineEdge, parent: NSWindow)?
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
    /// it's open. `colorId` is the Tabline's workspace, for the page-color previews.
    func toggle(anchor: NSRect, edge: TablineEdge, parent: NSWindow, colorId: WorkspaceColorId = .defaultColor()) {
        if isOpen { return close() }
        sheet.previewColor = colorId
        sheet.refresh()
        lastShow = (anchor, edge, parent)
        reposition()
        sheet.footer.updateTimer()
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
                     anchor: show.anchor, edge: TablineController.flyoutEdge(for: show.edge), topInset: 0, parent: show.parent,
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
