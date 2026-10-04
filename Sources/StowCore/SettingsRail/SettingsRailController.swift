import AppKit

/// Runs Settings in the rail: feeds SettingsRailView from the model, opens the workspace
/// editor and the app sheet beside the rail, previews page colors on a dwell, and asks
/// MainViewController to leave Settings.
@MainActor
final class SettingsRailController: NSObject {
    let view = SettingsRailView()
    private let model: AppModel
    /// Leave Settings for this workspace.
    var onLeave: ((UUID) -> Void)?
    /// Tint the rail with a workspace's page color, or nil for Settings' own.
    var onPreviewColor: ((WorkspaceColorId?) -> Void)?

    enum FlyoutId: Hashable { case editor, sheet, allShortcuts }

    /// The editor and the sheet are roots; All shortcuts is pushed beside the sheet.
    let flyouts = FlyoutController()
    private let editorPanel = FlyoutPanel()
    private let sheetPanel = FlyoutPanel()
    private let shortcutsPanel = FlyoutPanel()
    private let editor = WorkspaceEditorView()
    private let sheet = AppSheetView()
    /// The tip beside a resting tile; its dwell also previews the tile's page color.
    let tips = RailTipController()
    private(set) var editingId: UUID?
    private var isSheetOpen: Bool { flyouts.isOpen(id: FlyoutId.sheet) }
    private var previewId: UUID?
    /// The workspace the color panel is recoloring, and the color it shows. The drag
    /// previews it; the library is written once, when the editor or the panel closes.
    private var colorPanelWorkspace: UUID?
    private var pendingCustomColor: WorkspaceColorId?
    private var observesColorPanel = false

    init(model: AppModel) {
        self.model = model
        super.init()
        flyouts.onOutsideClick = { [weak self] in self?.closeFlyouts() }
        wireView()
        wireEditor()
        wireSheet()
        tips.onDwell = { [weak self] id in self?.preview(id) }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .stowAppPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .workspaceOpensInChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .tablineSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    var isFlyoutOpen: Bool { flyouts.isOpen }

    // MARK: Entering and leaving

    /// Settings returns to AppModel's active workspace, which stays the one you came
    /// from; there's no separate copy to keep in step. Kept for callers that announce entry.
    func didEnter(from workspaceId: UUID?) {}

    /// Where you came from, as the navigation rules see it.
    var navigation: SettingsRailNavigation {
        var navigation = SettingsRailNavigation()
        if !model.workspaces.isEmpty { navigation.didEnterSettings(from: model.activeWorkspaceId) }
        return navigation
    }

    var returnTarget: UUID? { navigation.returnTarget(in: model.workspaces.map(\.id)) }

    /// Tears down flyouts, tip and preview before the rail leaves Settings.
    func willLeave() {
        closeFlyouts()
        releaseColorPanel()
        tips.hide()
        previewId = nil
        // A focused gear or tile would keep its ring while hidden (⌘1 leaves from the keyboard).
        if let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
    }

    /// Esc: closes a flyout first, then leaves for the workspace you came from.
    func handleEscape() -> Bool {
        switch navigation.escapeAction(isOnSettings: true, flyoutOpen: isFlyoutOpen, workspaces: model.workspaces.map(\.id)) {
        case .closeFlyout:
            // A pushed flyout (All shortcuts) goes first, leaving the one it came from.
            if flyouts.openIds.count > 1 { flyouts.closeTop() } else { closeFlyouts() }
            return true
        case .leave(let id):
            onLeave?(id)
            return true
        case .none:
            return false
        }
    }

    // MARK: Reload

    func reload() {
        let workspaces = model.workspaces
        let identities = WorkspaceTileIdentity.resolve(workspaces)
        let tiles = workspaces.enumerated().map { index, ws in
            SettingsRailView.Tile(id: ws.id, name: ws.name, colorId: shownColor(of: ws),
                                  identity: identities[ws.id] ?? .letter("?"),
                                  accessibilityLabel: accessibilityLabel(for: ws, position: index + 1))
        }
        if let editingId, !workspaces.contains(where: { $0.id == editingId }) { closeEditor() }
        let returnName = returnTarget.flatMap { id in workspaces.first { $0.id == id }?.name }
        view.configure(tiles: tiles, cameFrom: navigation.cameFrom, selected: editingId, sheetOpen: isSheetOpen,
                       badge: AppSheet.showsBadge(needs: AppPreferences.shared.permissionNeeds), returnName: returnName)
        if let editingId, let ws = workspaces.first(where: { $0.id == editingId }) {
            editor.configure(editorContent(for: ws, identities: identities))
            positionEditor()
        }
        sheet.previewColor = returnTarget.flatMap { id in workspaces.first { $0.id == id }?.colorId } ?? .defaultColor()
        if isSheetOpen { positionSheet() }
        fetchMissingFavicons(workspaces)
    }

    private var requestedFavicons: Set<UUID> = []

    /// Mosaics need favicons; fetch them for the first few sites of each workspace, as
    /// the workspace rail does for its own links.
    private func fetchMissingFavicons(_ workspaces: [Workspace]) {
        for ws in workspaces where ws.icon == .favicons {
            let links = ws.items.flattenLinks().filter { !$0.isArchived }
            guard links.filter({ $0.faviconPath != nil }).count < 4 else { continue }
            for link in links.prefix(8) where link.faviconPath == nil && !requestedFavicons.contains(link.id) {
                guard let url = URL(string: link.url) else { continue }
                requestedFavicons.insert(link.id)
                FaviconService.shared.favicon(for: url, cachedPath: nil) { _, path in
                    guard let path else { return }
                    NotificationCenter.default.post(name: .init("UpdateLinkFavicon"), object: nil, userInfo: ["linkId": link.id, "path": path])
                }
            }
        }
    }

    private func accessibilityLabel(for ws: Workspace, position: Int) -> String {
        let name = ws.name.isEmpty ? "Untitled" : ws.name
        return "\(name), \(detail(for: ws, position: position))"
    }

    /// "18 items · Chrome · Work · ⌘1", as in the tip; the browser only when one is set.
    func detail(for ws: Workspace, position: Int) -> String {
        let count = WorkspaceDeletion.itemCount(of: ws)
        var parts = ["\(count) \(count == 1 ? "item" : "items")"]
        if let choice = OpensInStore().choice(for: ws.id) { parts.append(OpensInMenu.display(choice).title) }
        if let shortcut = WorkspaceShortcut.label(position: position) { parts.append(shortcut) }
        return parts.joined(separator: " · ")
    }

    func editorContent(for ws: Workspace, identities: [UUID: WorkspaceTileIdentity]) -> WorkspaceEditorView.Content {
        let position = (model.workspaces.firstIndex(where: { $0.id == ws.id }) ?? 0) + 1
        let favicons = WorkspaceIconSites.pick(from: ws.items)
        // The Letter choice previews what the tile would read among every workspace.
        let asLetters = model.workspaces.map { other -> Workspace in
            var other = other
            if other.id == ws.id { other.icon = .letter }
            return other
        }
        let letter = WorkspaceTileIdentity.resolve(asLetters)[ws.id] ?? .letter("?")
        let choice = OpensInStore().choice(for: ws.id)
        return .init(id: ws.id, name: ws.name, colorId: shownColor(of: ws), icon: ws.icon,
                     favicons: .mosaic(favicons), letter: letter,
                     current: identities[ws.id] ?? .letter("?"),
                     itemCount: WorkspaceDeletion.itemCount(of: ws), position: position,
                     opensIn: OpensInMenu.display(choice),
                     opensInNow: choice == nil ? OpensInMenu.currentBrowserName() : nil,
                     canDelete: model.workspaces.count > 1)
    }

    // MARK: View events

    private func wireView() {
        view.onGear = { [weak self] in
            guard let self, let id = self.returnTarget else { return }
            self.onLeave?(id)
        }
        view.onTileClick = { [weak self] id in
            guard let self else { return }
            if self.editingId == id { self.closeEditor() } else { self.openEditor(id) }
        }
        view.onTileDoubleClick = { [weak self] id in
            self?.onLeave?(id)
        }
        view.onTileMenu = { [weak self] id, anchor in
            guard let self else { return }
            let menu = WorkspaceMenu.make(for: id, model: self.model, presentingView: self.view) { [weak self] id in
                self?.openEditor(id, focusName: true)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.width - 4, y: 0), in: anchor)
        }
        view.onTileHover = { [weak self] id, inside in
            guard let self else { return }
            if inside { self.tips.pointerEntered(id) } else { self.tips.pointerExited(id) }
        }
        view.onTileFocus = { [weak self] id in self?.tips.focusChanged(id) }
        view.onDragBegan = { [weak self] in
            guard let self else { return }
            self.closeFlyouts()
            self.tips.hide()
            self.preview(nil)
        }
        view.onReorder = { [weak self] id, index in
            self?.model.reorderWorkspace(id: id, toIndex: index)
        }
        view.onAdd = { [weak self] in self?.createWorkspace() }
        view.onQuiet = { [weak self] in
            guard let self else { return }
            if self.isSheetOpen { self.closeFlyouts() } else { self.openSheet() }
        }
        view.onBackgroundClick = { [weak self] in self?.closeFlyouts() }
    }

    private func createWorkspace() {
        let lastViewed = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        let cameFrom = returnTarget
        let id = model.createWorkspace(name: "", colorId: SettingsRailNewWorkspace.color(existing: model.workspaces.map(\.colorId)))
        // Creating selects the new workspace; stay on Settings and keep where you came from
        // as the active workspace (the main view reloads once, after both steps).
        if let cameFrom { model.selectWorkspace(id: cameFrom) }
        model.selectSettings()
        UserDefaults.standard.set(lastViewed, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        reload()
        view.scrollTileToVisible(id)
        openEditor(id, focusName: true)
    }

    // MARK: Preview

    private func preview(_ id: UUID?) {
        // Focus can come back to a tile a turn after the rail has gone (closing the editor
        // makes the window key again); a hidden rail previews nothing.
        guard !view.isHiddenOrHasHiddenAncestor, view.window != nil else {
            previewId = nil
            hideTip()
            return
        }
        let workspace = id.flatMap { id in model.workspaces.first { $0.id == id } }
        previewId = workspace?.id
        onPreviewColor?(workspace?.colorId)
        let colors = StowTheme.colors(for: workspace?.colorId ?? .settingsBackground, tint: StowTheme.displayTint)
        view.setColors(colors)
        if let workspace, editingId == nil, !isSheetOpen {
            showTip(for: workspace)
        } else {
            hideTip()
        }
    }

    private func showTip(for ws: Workspace) {
        guard let window = view.window, let anchor = view.screenFrame(ofTile: ws.id) else { return }
        let position = (model.workspaces.firstIndex(where: { $0.id == ws.id }) ?? 0) + 1
        tips.show(.init(title: ws.name.isEmpty ? "Untitled" : ws.name, detail: detail(for: ws, position: position)),
                  anchor: anchor, column: railScreenFrame(), parent: window)
    }

    /// Hides the tip; the dwell keeps previewing the hovered tile's color.
    private func hideTip() {
        tips.hide(resettingDwell: false)
    }

    private func railScreenFrame() -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: Editor

    private func openEditor(_ id: UUID, focusName: Bool = false) {
        closeSheet()
        hideTip()
        commitPendingName()
        if id != editingId { releaseColorPanel() }
        editingId = id
        reload()
        if focusName {
            editorPanel.makeKey()
            editor.focusName()
        } else {
            // Only a new workspace takes the name field; otherwise the rail keeps the keyboard.
            editorPanel.makeFirstResponder(nil)
            view.window?.makeKey()
        }
    }

    private func closeEditor() {
        commitPendingName()
        editingId = nil
        flyouts.close(id: FlyoutId.editor)
        releaseColorPanel()
        view.window?.makeKey()
        reload()
    }

    /// A workspace can't be left nameless; an empty name becomes "Untitled".
    private func commitPendingName() {
        guard let id = editingId, let ws = model.workspaces.first(where: { $0.id == id }),
              ws.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.renameWorkspace(id: id, newName: "Untitled")
    }

    private func positionEditor() {
        guard let id = editingId, let window = view.window, let anchor = view.screenFrame(ofTile: id) else { return }
        let size = NSSize(width: WorkspaceEditorView.width, height: editor.preferredHeight)
        flyouts.show(editorPanel, id: FlyoutId.editor, content: editor, size: size, anchor: anchor,
                     edge: .beside(column: railScreenFrame()), topInset: 28, parent: window,
                     onEscape: { [weak self] in self?.closeFlyouts() })
    }

    private func wireEditor() {
        editor.onHeightChange = { [weak self] in self?.positionEditor() }
        editor.onRename = { [weak self] name in
            guard let self, let id = self.editingId else { return }
            self.model.renameWorkspace(id: id, newName: name)
        }
        editor.onCommit = { [weak self] in self?.closeEditor() }
        editor.onEscape = { [weak self] in self?.closeEditor() }
        editor.onColor = { [weak self] colorId in
            guard let self, let id = self.editingId else { return }
            self.pendingCustomColor = nil
            self.model.updateWorkspaceColor(id: id, colorId: colorId)
        }
        editor.onCustomColor = { [weak self] in self?.chooseCustomColor() }
        editor.onIcon = { [weak self] icon in
            guard let self, let id = self.editingId else { return }
            self.model.updateWorkspaceIcon(id: id, icon: icon)
        }
        editor.opensInMenu = { [weak self] in
            guard let self, let id = self.editingId else { return nil }
            return WorkspaceMenu.makeOpensInMenu(for: id)
        }
        editor.onOpen = { [weak self] in
            guard let self, let id = self.editingId else { return }
            self.onLeave?(id)
        }
        editor.onShare = { [weak self] in
            guard let self, let id = self.editingId, let ws = self.model.workspaces.first(where: { $0.id == id }),
                  let url = try? self.model.shareWorkspace(id: id) else { return }
            SharePanel.show(url: url, workspaceName: ws.name)
        }
        editor.onDelete = { [weak self] in
            guard let self, let id = self.editingId, self.model.workspaces.count > 1 else { return }
            self.editingId = nil
            self.flyouts.close(id: FlyoutId.editor)
            self.releaseColorPanel(commit: false)
            // The main window takes the keyboard back, so ⌘Z reaches its undo manager.
            self.view.window?.makeKey()
            WorkspaceDeletion.delete(id, model: self.model, in: self.view.window)
        }
    }

    func chooseCustomColor() {
        guard let id = editingId, let ws = model.workspaces.first(where: { $0.id == id }) else { return }
        colorPanelWorkspace = id
        pendingCustomColor = nil
        let panel = NSColorPanel.shared
        panel.color = ws.colorId.color
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        if !observesColorPanel {
            observesColorPanel = true
            NotificationCenter.default.addObserver(self, selector: #selector(colorPanelWillClose),
                                                   name: NSWindow.willCloseNotification, object: panel)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Each tick of the drag previews the color on the rail and in the editor; nothing is
    /// written until the editor or the panel closes.
    @objc func customColorChanged(_ sender: Any?) {
        guard let id = colorPanelWorkspace, id == editingId else { return }
        let color = WorkspaceColorId.custom(NSColorPanel.shared.color.hexString)
        pendingCustomColor = color
        onPreviewColor?(color)
        view.setColors(StowTheme.colors(for: color, tint: StowTheme.displayTint))
        reload()
    }

    @objc private func colorPanelWillClose() {
        releaseColorPanel()
    }

    /// Commits the previewed custom color once, then lets go of the color panel so it
    /// can't recolor a workspace whose editor has closed.
    private func releaseColorPanel(commit: Bool = true) {
        if commit, let id = colorPanelWorkspace, let color = pendingCustomColor,
           model.workspaces.contains(where: { $0.id == id }) {
            model.updateWorkspaceColor(id: id, colorId: color)
        }
        pendingCustomColor = nil
        guard colorPanelWorkspace != nil else { return }
        colorPanelWorkspace = nil
        // The panel's target can't be read back; while colorPanelWorkspace is set it's ours.
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// The color a workspace shows: the color panel's preview while it's being dragged.
    private func shownColor(of ws: Workspace) -> WorkspaceColorId {
        if ws.id == colorPanelWorkspace, let pendingCustomColor { return pendingCustomColor }
        return ws.colorId
    }

    // MARK: Sheet

    private func openSheet() {
        if editingId != nil { closeEditor() }
        hideTip()
        sheet.refresh()
        positionSheet()
        sheet.footer.updateTimer()
        reload()
    }

    private func closeSheet() {
        guard isSheetOpen else { return }
        flyouts.close(id: FlyoutId.sheet)
        sheet.footer.updateTimer()
        view.window?.makeKey()
        reload()
    }

    private func positionSheet() {
        guard let window = view.window, let anchor = view.screenFrameOfQuietCell() else { return }
        let height = sheet.preferredHeight
        sheet.frame.size.height = height
        flyouts.show(sheetPanel, id: FlyoutId.sheet, content: sheet, size: NSSize(width: AppSheetView.width, height: height),
                     anchor: anchor, edge: .beside(column: railScreenFrame()), topInset: height - 25, parent: window,
                     onEscape: { [weak self] in self?.closeFlyouts() })
        if flyouts.isOpen(id: FlyoutId.allShortcuts), let link = shortcutsAnchor, let rect = screenFrame(of: link) {
            showAllShortcuts(from: rect)
        }
    }

    // MARK: All shortcuts

    private weak var shortcutsAnchor: NSView?

    /// Pushes All shortcuts beside the sheet, its arrow on `anchor` (screen coordinates).
    func showAllShortcuts(from anchor: NSRect) {
        guard isSheetOpen else { return }
        // Built fresh on open so the Any app rows show the current hotkeys.
        let shown = flyouts.isOpen(id: FlyoutId.allShortcuts) ? shortcutsPanel.content as? AllShortcutsView : nil
        let list = shown ?? AllShortcutsView()
        flyouts.push(shortcutsPanel, id: FlyoutId.allShortcuts, content: list, size: list.preferredSize,
                     anchor: anchor, topInset: 24)
    }

    private func screenFrame(of view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func wireSheet() {
        sheet.onHeightChange = { [weak self] in
            guard let self, self.isSheetOpen else { return }
            self.positionSheet()
        }
        sheet.onImport = {
            NotificationCenter.default.post(name: .stowShowImport, object: nil)
        }
        sheet.onShowAllShortcuts = { [weak self] link in
            guard let self, let rect = self.screenFrame(of: link) else { return }
            self.shortcutsAnchor = link
            self.flyouts.toggle(id: FlyoutId.allShortcuts) { self.showAllShortcuts(from: rect) }
        }
    }

    // MARK: Closing

    func closeFlyouts() {
        if editingId != nil { closeEditor() }
        closeSheet()
        hideTip()
        flyouts.closeAll()
    }

    /// Whether a click in this window, seen by the outside-click monitor, closes the
    /// flyouts. FlyoutDismissPolicy decides; this keeps the rail's older entry point.
    static func clickClosesFlyouts(inFlyout: Bool, inRail: Bool, isColorPanel: Bool, windowClassName: String?) -> Bool {
        FlyoutDismissPolicy.clickCloses(inStack: inFlyout, inHost: inRail, isColorPanel: isColorPanel, windowClassName: windowClassName)
    }

    /// Whether the Settings rail is on screen; sidebar mode and the workspace page hide it.
    var isRailVisible: Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    @objc private func preferencesChanged() {
        guard isRailVisible else { return }
        reload()
    }
}
