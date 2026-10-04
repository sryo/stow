import AppKit

/// The one workspace editor: WorkspaceEditorView in a FlyoutPanel beside whatever opened
/// it. A right-click on any workspace opens it: a rail dot, a Color Strip tab, a "More
/// workspaces" row, the Tabline chip or a row in its list. "New workspace…" (⌘N, the
/// title-row "+", the rail's "+" dot, a swipe past the last page) opens it on a workspace
/// that doesn't exist yet, which is created only when it's committed.
///
/// Every change to an existing workspace is written as it's made, except a custom colour:
/// the colour panel's drag previews it, and it's written once, when the editor or the
/// panel closes.
@MainActor
final class WorkspaceEditorController: NSObject {
    /// Where the card goes. `anchor` is in screen coordinates.
    struct Placement {
        var anchor: NSRect
        var edge: FlyoutPanel.Edge
        var topInset: CGFloat = 28
        var parent: NSWindow
    }

    /// Which side of its anchor the card opens on: under a strip tab or the title "+",
    /// over a Tabline riding the bottom edge, or beside the window for a rail dot.
    enum AnchorEdge { case below, above, besideWindow }

    static func placement(anchor: NSRect, parent: NSWindow, edge: AnchorEdge) -> Placement {
        switch edge {
        case .below: return .init(anchor: anchor, edge: .below, topInset: 0, parent: parent)
        case .above: return .init(anchor: anchor, edge: .above, topInset: 0, parent: parent)
        case .besideWindow: return .init(anchor: anchor, edge: .beside(column: parent.frame), topInset: 28, parent: parent)
        }
    }

    /// How many editors exist; the main window keeps exactly one.
    nonisolated(unsafe) static var liveCount = 0

    private let model: AppModel
    let flyouts = FlyoutController()
    private let flyoutId: AnyHashable = "workspaceEditor"
    let panel = FlyoutPanel()
    let editor = WorkspaceEditorView()
    private(set) var editingId: UUID?
    private var placement: (() -> Placement?)?
    private weak var parentWindow: NSWindow?

    /// The workspace "New workspace…" is naming, before it exists, and the items it
    /// takes with it (Move to › New workspace…).
    private var draft: Workspace?
    private var draftMoving: [UUID] = []

    /// Open ↩: show this workspace.
    var onOpenWorkspace: ((UUID) -> Void)?
    /// Each tick of a custom-colour drag, before anything is written.
    var onPreviewColor: ((WorkspaceColorId) -> Void)?
    /// After the editor closes, by any path.
    var onClose: (() -> Void)?
    /// A new workspace was committed and created.
    var onCreated: ((UUID) -> Void)?
    /// A new workspace was abandoned (Esc, or closed without a name).
    var onNewCancelled: (() -> Void)?
    /// Export…: asks where to save and writes the workspace there.
    var export: (UUID, NSWindow?) -> Void

    /// The color panel's workspace, and the color it shows.
    private var colorPanelWorkspace: UUID?
    private var pendingCustomColor: WorkspaceColorId?
    private var observesColorPanel = false

    init(model: AppModel) {
        self.model = model
        export = { id, window in WorkspaceExport.run(id, model: model, in: window) }
        super.init()
        Self.liveCount += 1
        flyouts.onOutsideClick = { [weak self] in self?.close() }
        wireEditor()
    }

    deinit {
        Self.liveCount -= 1
    }

    var isOpen: Bool { editingId != nil && flyouts.isOpen(id: flyoutId) }
    /// Whether the card is naming a workspace that doesn't exist yet.
    var isNew: Bool { draft != nil && editingId == draft?.id }

    private func workspace(_ id: UUID) -> Workspace? {
        if let draft, draft.id == id { return draft }
        return model.workspaces.first { $0.id == id }
    }

    // MARK: Opening and closing

    /// Opens the editor on `id` where `placement` says, asked again whenever the editor
    /// grows or the library changes. Only `focusName` takes the keyboard.
    func open(_ id: UUID, placement: @escaping () -> Placement?, focusName: Bool = false) {
        if draft != nil, draft?.id != id { finishNew(create: draftHasName) }
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

    /// Opens the editor on a new, empty, unnamed workspace with its name focused. Nothing
    /// is created until it's committed; `moving` items go into it then.
    func beginNew(moving nodeIds: [UUID] = [], placement: @escaping () -> Placement?) {
        if draft != nil { finishNew(create: draftHasName) }
        let colorId = NewWorkspaceColor.pick(existing: model.workspaces.map(\.colorId))
        let new = Workspace(id: UUID(), name: "", colorId: colorId, items: [])
        draft = new
        draftMoving = nodeIds
        open(new.id, placement: placement, focusName: true)
    }

    /// Closes the card (an outside click, or the window moving on). A new workspace is
    /// created only if it was given a name; an existing one keeps its pending name and
    /// colour.
    func close() {
        if isNew { return finishNew(create: draftHasName) }
        guard editingId != nil || flyouts.isOpen(id: flyoutId) else { return }
        commitPendingName()
        editingId = nil
        flyouts.close(id: flyoutId)
        releaseColorPanel()
        parentWindow?.makeKey()
        onClose?()
    }

    /// Esc: like `close`, except that a new workspace is never created.
    func cancel() {
        if isNew { return finishNew(create: false) }
        close()
    }

    /// Return, and Create ↩ on a new workspace, which is created even while unnamed.
    func commit() {
        if isNew { return finishNew(create: true) }
        close()
    }

    private var draftHasName: Bool {
        !(draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    private func finishNew(create: Bool) {
        guard var new = draft else { return }
        if new.id == colorPanelWorkspace, let pendingCustomColor { new.colorId = pendingCustomColor }
        let moving = draftMoving
        draft = nil
        draftMoving = []
        releaseColorPanel(commit: false)
        if editingId == new.id {
            editingId = nil
            flyouts.close(id: flyoutId)
        }
        parentWindow?.makeKey()
        guard create else {
            OpensInStore().set(nil, for: new.id)
            onClose?()
            onNewCancelled?()
            return
        }
        if new.name.trimmingCharacters(in: .whitespaces).isEmpty { new.name = "Untitled" }
        let source = model.activeWorkspaceId
        let id = model.createWorkspace(id: new.id, name: new.name, colorId: new.colorId, icon: new.icon)
        if !moving.isEmpty {
            // Items move out of the workspace they're in, which creating just switched away from.
            model.selectWorkspace(id: source)
            model.moveNodesToWorkspace(nodeIds: moving, toWorkspaceId: id)
        }
        onClose?()
        onCreated?(id)
    }

    /// Re-reads the workspace and moves the card to its anchor; closes it when the
    /// workspace is gone.
    func refresh() {
        guard let id = editingId else { return }
        guard let ws = workspace(id) else { return close() }
        editor.configure(editorContent(for: ws, identities: WorkspaceTileIdentity.resolve(allWorkspaces)))
        position()
    }

    /// The library, with the new workspace being named at its end.
    private var allWorkspaces: [Workspace] {
        model.workspaces + (draft.map { [$0] } ?? [])
    }

    private func position() {
        guard editingId != nil, let place = placement?() else { return }
        parentWindow = place.parent
        panel.level = place.parent.level
        let size = NSSize(width: WorkspaceEditorView.width, height: editor.preferredHeight)
        flyouts.show(panel, id: flyoutId, content: editor, size: size, anchor: place.anchor,
                     edge: place.edge, topInset: place.topInset, parent: place.parent,
                     onEscape: { [weak self] in self?.cancel() })
    }

    /// A workspace can't be left nameless; an empty name becomes "Untitled".
    private func commitPendingName() {
        guard let id = editingId, !isNew, let ws = model.workspaces.first(where: { $0.id == id }),
              ws.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.renameWorkspace(id: id, newName: "Untitled")
    }

    // MARK: Content

    func editorContent(for ws: Workspace, identities: [UUID: WorkspaceTileIdentity]) -> WorkspaceEditorView.Content {
        let all = allWorkspaces
        let position = (all.firstIndex(where: { $0.id == ws.id }) ?? 0) + 1
        let favicons = WorkspaceIconSites.pick(from: ws.items)
        // The Letter choice previews what the tile would read among every workspace.
        let asLetters = all.map { other -> Workspace in
            var other = other
            if other.id == ws.id { other.icon = .letter }
            return other
        }
        let letter = WorkspaceTileIdentity.resolve(asLetters)[ws.id] ?? .letter("?")
        let choice = OpensInStore().choice(for: ws.id)
        let isNew = ws.id == draft?.id
        return .init(id: ws.id, name: ws.name, colorId: shownColor(of: ws), icon: ws.icon,
                     favicons: .mosaic(favicons), letter: letter,
                     current: identities[ws.id] ?? .letter("?"),
                     itemCount: ws.items.activeItemCount(), position: position,
                     opensIn: OpensInMenu.display(choice),
                     opensInNow: choice == nil ? OpensInMenu.currentBrowserName() : nil,
                     canDelete: !isNew && model.workspaces.count > 1, isNew: isNew)
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
            if self.isNew {
                self.draft?.name = name
                self.refresh()
            } else {
                self.model.renameWorkspace(id: id, newName: name)
            }
        }
        editor.onCommit = { [weak self] in self?.commit() }
        editor.onEscape = { [weak self] in self?.cancel() }
        editor.onColor = { [weak self] colorId in
            guard let self, let id = self.editingId else { return }
            self.pendingCustomColor = nil
            if self.isNew {
                self.draft?.colorId = colorId
                self.refresh()
            } else {
                self.model.updateWorkspaceColor(id: id, colorId: colorId)
            }
        }
        editor.onCustomColor = { [weak self] in self?.chooseCustomColor() }
        editor.onIcon = { [weak self] icon in
            guard let self, let id = self.editingId else { return }
            if self.isNew {
                self.draft?.icon = icon
                self.refresh()
            } else {
                self.model.updateWorkspaceIcon(id: id, icon: icon)
            }
        }
        editor.opensInMenu = { [weak self] in
            guard let self, let id = self.editingId else { return nil }
            return OpensInMenu.make(forWorkspace: id)
        }
        editor.onOpen = { [weak self] in
            guard let self, let id = self.editingId else { return }
            if self.isNew { return self.commit() }
            self.onOpenWorkspace?(id)
        }
        editor.onShare = { [weak self] in
            guard let self, !self.isNew, let id = self.editingId,
                  let ws = self.model.workspaces.first(where: { $0.id == id }) else { return }
            do {
                SharePanel.show(url: try self.model.shareWorkspace(id: id), workspaceName: ws.name)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Share failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        editor.onExport = { [weak self] in
            guard let self, !self.isNew, let id = self.editingId else { return }
            self.export(id, self.parentWindow)
        }
        editor.onDelete = { [weak self] in
            guard let self, !self.isNew, let id = self.editingId, self.model.workspaces.count > 1 else { return }
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
        guard let id = editingId, let ws = workspace(id) else { return }
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
    /// can't recolor a workspace whose editor has closed. A new workspace takes the
    /// colour into its draft instead.
    func releaseColorPanel(commit: Bool = true) {
        if commit, let id = colorPanelWorkspace, let color = pendingCustomColor {
            if id == draft?.id {
                draft?.colorId = color
            } else if model.workspaces.contains(where: { $0.id == id }) {
                model.updateWorkspaceColor(id: id, colorId: color)
            }
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
