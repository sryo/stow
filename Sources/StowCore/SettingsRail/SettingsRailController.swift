import AppKit

/// Runs Settings in the rail: feeds SettingsRailView from the model, opens the workspace
/// editor and the app sheet beside the rail, previews page colors on a dwell, and asks
/// MainViewController to leave Settings.
@MainActor
final class SettingsRailController: NSObject {
    let view = SettingsRailView()
    private let model: AppModel
    private(set) var navigation = SettingsRailNavigation()
    /// Leave Settings for this workspace.
    var onLeave: ((UUID) -> Void)?
    /// Tint the rail with a workspace's page color, or nil for Settings' own.
    var onPreviewColor: ((WorkspaceColorId?) -> Void)?

    private let editorPanel = RailFlyoutPanel()
    private let sheetPanel = RailFlyoutPanel()
    private let tipPanel = RailFlyoutPanel(takesKey: false)
    private let editor = WorkspaceEditorView()
    private let sheet = AppSheetView()
    private let tip = TileTipView()
    private(set) var editingId: UUID?
    private var isSheetOpen: Bool { sheetPanel.isVisible }
    private lazy var dwell = HoverDwell(clock: MainQueueDwellClock())
    private var previewId: UUID?
    private var mouseMonitor: Any?
    private var colorPanelWorkspace: UUID?

    init(model: AppModel) {
        self.model = model
        super.init()
        tipPanel.showsArrow = false
        tipPanel.cornerRadius = 9
        tipPanel.ignoresMouseEvents = true
        editorPanel.onEscape = { [weak self] in self?.closeFlyouts() }
        sheetPanel.onEscape = { [weak self] in self?.closeFlyouts() }
        wireView()
        wireEditor()
        wireSheet()
        dwell.onPreview = { [weak self] id in self?.preview(id) }
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .stowAppPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .workspaceOpensInChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: .tablineSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    var isFlyoutOpen: Bool { editorPanel.isVisible || sheetPanel.isVisible }

    // MARK: Entering and leaving

    func didEnter(from workspaceId: UUID?) {
        navigation.didEnterSettings(from: workspaceId)
    }

    var returnTarget: UUID? { navigation.returnTarget(in: model.workspaces.map(\.id)) }

    /// Tears down flyouts, tip and preview before the rail leaves Settings.
    func willLeave() {
        closeFlyouts()
        dwell.reset()
        hideTip()
        previewId = nil
    }

    /// Esc: closes a flyout first, then leaves for the workspace you came from.
    func handleEscape() -> Bool {
        switch navigation.escapeAction(isOnSettings: true, flyoutOpen: isFlyoutOpen, workspaces: model.workspaces.map(\.id)) {
        case .closeFlyout:
            closeFlyouts()
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
            SettingsRailView.Tile(id: ws.id, name: ws.name, colorId: ws.colorId,
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

    /// "18 items · Chrome · Work · ⌃1", as in the tip; the browser only when one is set.
    private func detail(for ws: Workspace, position: Int) -> String {
        let count = WorkspaceDeletion.itemCount(of: ws)
        var parts = ["\(count) \(count == 1 ? "item" : "items")"]
        if let choice = OpensInStore().choice(for: ws.id) { parts.append(OpensInMenu.display(choice).title) }
        if position <= 9 { parts.append("⌃\(position)") }
        return parts.joined(separator: " · ")
    }

    private func editorContent(for ws: Workspace, identities: [UUID: WorkspaceTileIdentity]) -> WorkspaceEditorView.Content {
        let position = (model.workspaces.firstIndex(where: { $0.id == ws.id }) ?? 0) + 1
        let favicons = WorkspaceIconSites.pick(from: ws.items)
        var letterItems = [WorkspaceStripLayout.Item(id: ws.id, name: ws.name)]
        WorkspaceStripLayout.assignMonograms(&letterItems)
        let choice = OpensInStore().choice(for: ws.id)
        return .init(id: ws.id, name: ws.name, colorId: ws.colorId, icon: ws.icon,
                     favicons: .mosaic(favicons), letter: .letter(letterItems[0].monogram),
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
            if inside { self.dwell.pointerEntered(id) } else { self.dwell.pointerExited(id) }
        }
        view.onTileFocus = { [weak self] id in self?.dwell.focusChanged(id) }
        view.onDragBegan = { [weak self] in
            guard let self else { return }
            self.closeFlyouts()
            self.dwell.reset()
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
        let id = model.createWorkspace(name: "", colorId: SettingsRailNewWorkspace.color(existing: model.workspaces.map(\.colorId)))
        // Creating selects the new workspace; stay on Settings and keep where you came from.
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
        let colors = StowTheme.colors(for: workspace?.colorId ?? .settingsBackground, tint: StowTheme.preferredTint)
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
        tip.set(name: ws.name.isEmpty ? "Untitled" : ws.name, detail: detail(for: ws, position: position))
        let size = tip.fittingSize
        tipPanel.present(tip, size: size, anchor: anchor, rail: railScreenFrame(), topInset: anchor.height / 2 - 4, parent: window)
    }

    private func hideTip() {
        if tipPanel.isVisible { tipPanel.dismiss() }
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
        editingId = id
        editor.setConfirming(false)
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
        editor.setConfirming(false)
        if editorPanel.isVisible { editorPanel.dismiss() }
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
        editorPanel.present(editor, size: size, anchor: anchor, rail: railScreenFrame(), topInset: 28, parent: window)
        installMouseMonitor()
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
        editor.onDelete = { [weak self] in
            guard let self, let id = self.editingId, self.model.workspaces.count > 1 else { return }
            self.editingId = nil
            self.editor.setConfirming(false)
            self.editorPanel.dismiss()
            self.model.deleteWorkspace(id: id)
        }
    }

    private func chooseCustomColor() {
        guard let id = editingId, let ws = model.workspaces.first(where: { $0.id == id }) else { return }
        colorPanelWorkspace = id
        let panel = NSColorPanel.shared
        panel.color = ws.colorId.color
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: Any?) {
        guard let id = colorPanelWorkspace else { return }
        model.updateWorkspaceColor(id: id, colorId: .custom(NSColorPanel.shared.color.hexString))
    }

    // MARK: Sheet

    private func openSheet() {
        if editingId != nil { closeEditor() }
        hideTip()
        sheet.refresh()
        positionSheet()
        reload()
    }

    private func closeSheet() {
        guard sheetPanel.isVisible else { return }
        sheetPanel.dismiss()
        view.window?.makeKey()
        reload()
    }

    private func positionSheet() {
        guard let window = view.window, let anchor = view.screenFrameOfQuietCell() else { return }
        let height = sheet.preferredHeight
        sheet.frame.size.height = height
        sheetPanel.present(sheet, size: NSSize(width: AppSheetView.width, height: height), anchor: anchor,
                           rail: railScreenFrame(), topInset: height - 25, parent: window)
        installMouseMonitor()
    }

    private func wireSheet() {
        sheet.onHeightChange = { [weak self] in
            guard let self, self.isSheetOpen else { return }
            self.positionSheet()
        }
        sheet.onImport = {
            NotificationCenter.default.post(name: .stowShowImport, object: nil)
        }
    }

    // MARK: Closing

    func closeFlyouts() {
        if editingId != nil { closeEditor() }
        closeSheet()
        hideTip()
        removeMouseMonitor()
    }

    /// Clicks in another of Stow's windows close the flyouts; clicks on the rail are
    /// handled by the rail itself.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let inFlyout = event.window === self.editorPanel || event.window === self.sheetPanel
            let inRail = event.window === self.view.window
            let inMenuOrPanel = event.window is NSColorPanel || event.window?.className.contains("Menu") == true
            if !inFlyout && !inRail && !inMenuOrPanel { self.closeFlyouts() }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    @objc private func appResigned() {
        hideTip()
    }

    @objc private func preferencesChanged() {
        reload()
    }
}

/// The tip beside a resting tile: the full name, then items, profile and shortcut.
@MainActor
private final class TileTipView: RailFlippedView {
    private let name = FlyoutLabel.text("", size: 12.5, weight: .semibold)
    private let detail = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)

    init() {
        super.init(frame: .zero)
        addSubview(name)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(name: String, detail: String) {
        self.name.stringValue = name
        self.detail.stringValue = detail
        // Labels inset their text 2pt each side; the tip's text sits 10pt in.
        func width(_ label: NSTextField) -> CGFloat {
            (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width + 6
        }
        let text = ceil(max(width(self.name), width(self.detail)))
        frame.size = NSSize(width: text + 16, height: 6 + 16 + 14 + 6)
        self.name.frame = NSRect(x: 8, y: 6, width: text, height: 16)
        self.detail.frame = NSRect(x: 8, y: 22, width: text, height: 14)
    }

    override var fittingSize: NSSize { frame.size }
}
