import AppKit

/// The one workspace editor: WorkspaceEditorView in a FlyoutPanel, beside whatever opened
/// it. The Settings rail opens it beside a tile, the Settings page beside a row, and the
/// WorkspaceMenu's Edit… beside a rail dot, a title-bar tab or the Tabline chip.
///
/// Every change is written as it's made, except a custom colour: the colour panel's drag
/// previews it, and it's written once, when the editor or the panel closes.
@MainActor
final class WorkspaceEditorController: NSObject {
    /// Where the card goes. `anchor` is in screen coordinates.
    struct Placement {
        var anchor: NSRect
        var edge: FlyoutPanel.Edge
        var topInset: CGFloat = 28
        var parent: NSWindow
    }

    private let model: AppModel
    /// The stack the editor is shown in: its own, or a host's (the Settings rail keeps
    /// the editor and its app sheet in one stack).
    let flyouts: FlyoutController
    private let flyoutId: AnyHashable
    let panel = FlyoutPanel()
    let editor = WorkspaceEditorView()
    private(set) var editingId: UUID?
    private var placement: (() -> Placement?)?
    private weak var parentWindow: NSWindow?

    /// Open ↩: show this workspace.
    var onOpenWorkspace: ((UUID) -> Void)?
    /// Each tick of a custom-colour drag, before anything is written.
    var onPreviewColor: ((WorkspaceColorId) -> Void)?
    /// After the editor closes, by any path.
    var onClose: (() -> Void)?

    /// The workspace the color panel is recoloring, and the color it shows.
    private var colorPanelWorkspace: UUID?
    private var pendingCustomColor: WorkspaceColorId?
    private var observesColorPanel = false

    init(model: AppModel, flyouts: FlyoutController? = nil, flyoutId: AnyHashable = "workspaceEditor") {
        self.model = model
        self.flyoutId = flyoutId
        self.flyouts = flyouts ?? FlyoutController()
        super.init()
        // A host's stack routes outside clicks itself; our own closes through `close`.
        if flyouts == nil { self.flyouts.onOutsideClick = { [weak self] in self?.close() } }
        wireEditor()
    }

    var isOpen: Bool { editingId != nil && flyouts.isOpen(id: flyoutId) }

    // MARK: Opening and closing

    /// Opens the editor on `id` where `placement` says, asked again whenever the editor
    /// grows or the library changes. Only `focusName` (a new workspace) takes the keyboard.
    func open(_ id: UUID, placement: @escaping () -> Placement?, focusName: Bool = false) {
        commitPendingName()
        if id != editingId { releaseColorPanel() }
        editingId = id
        self.placement = placement
        refresh()
        if focusName {
            panel.makeKey()
            editor.focusName()
        } else {
            panel.makeFirstResponder(nil)
            parentWindow?.makeKey()
        }
    }

    /// Commits a pending name and colour, closes the card and gives the keyboard back.
    func close() {
        guard editingId != nil || flyouts.isOpen(id: flyoutId) else { return }
        commitPendingName()
        editingId = nil
        flyouts.close(id: flyoutId)
        releaseColorPanel()
        parentWindow?.makeKey()
        onClose?()
    }

    /// Re-reads the workspace and moves the card to its anchor; closes it when the
    /// workspace is gone.
    func refresh() {
        guard let id = editingId else { return }
        guard let ws = model.workspaces.first(where: { $0.id == id }) else { return close() }
        editor.configure(editorContent(for: ws, identities: WorkspaceTileIdentity.resolve(model.workspaces)))
        position()
    }

    private func position() {
        guard editingId != nil, let place = placement?() else { return }
        parentWindow = place.parent
        let size = NSSize(width: WorkspaceEditorView.width, height: editor.preferredHeight)
        flyouts.show(panel, id: flyoutId, content: editor, size: size, anchor: place.anchor,
                     edge: place.edge, topInset: place.topInset, parent: place.parent,
                     onEscape: { [weak self] in self?.close() })
    }

    /// A workspace can't be left nameless; an empty name becomes "Untitled".
    private func commitPendingName() {
        guard let id = editingId, let ws = model.workspaces.first(where: { $0.id == id }),
              ws.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.renameWorkspace(id: id, newName: "Untitled")
    }

    // MARK: Content

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
                     itemCount: ws.items.activeItemCount(), position: position,
                     opensIn: OpensInMenu.display(choice),
                     opensInNow: choice == nil ? OpensInMenu.currentBrowserName() : nil,
                     canDelete: model.workspaces.count > 1)
    }

    /// The color a workspace shows: the color panel's preview while it's being dragged.
    func shownColor(of ws: Workspace) -> WorkspaceColorId {
        if ws.id == colorPanelWorkspace, let pendingCustomColor { return pendingCustomColor }
        return ws.colorId
    }

    // MARK: Editor events

    private func wireEditor() {
        editor.onHeightChange = { [weak self] in self?.position() }
        editor.onRename = { [weak self] name in
            guard let self, let id = self.editingId else { return }
            self.model.renameWorkspace(id: id, newName: name)
        }
        editor.onCommit = { [weak self] in self?.close() }
        editor.onEscape = { [weak self] in self?.close() }
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
            self.onOpenWorkspace?(id)
        }
        editor.onShare = { [weak self] in
            guard let self, let id = self.editingId, let ws = self.model.workspaces.first(where: { $0.id == id }),
                  let url = try? self.model.shareWorkspace(id: id) else { return }
            SharePanel.show(url: url, workspaceName: ws.name)
        }
        editor.onDelete = { [weak self] in
            guard let self, let id = self.editingId, self.model.workspaces.count > 1 else { return }
            self.editingId = nil
            self.flyouts.close(id: self.flyoutId)
            self.releaseColorPanel(commit: false)
            // The main window takes the keyboard back, so ⌘Z reaches its undo manager.
            self.parentWindow?.makeKey()
            WorkspaceDeletion.delete(id, model: self.model, in: self.parentWindow)
            self.onClose?()
        }
    }

    // MARK: Custom colour

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

    /// Each tick of the drag previews the color; nothing is written until the editor or
    /// the panel closes.
    @objc func customColorChanged(_ sender: Any?) {
        guard let id = colorPanelWorkspace, id == editingId else { return }
        let color = WorkspaceColorId.custom(NSColorPanel.shared.color.hexString)
        pendingCustomColor = color
        onPreviewColor?(color)
        refresh()
    }

    @objc private func colorPanelWillClose() {
        releaseColorPanel()
    }

    /// Commits the previewed custom color once, then lets go of the color panel so it
    /// can't recolor a workspace whose editor has closed.
    func releaseColorPanel(commit: Bool = true) {
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
}
