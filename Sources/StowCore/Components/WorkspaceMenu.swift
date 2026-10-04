import AppKit
import UniformTypeIdentifiers

/// The one workspace menu, everywhere a workspace shows (rail tile, Settings row "…",
/// title-bar switcher): Rename · Color › · Icon › · Opens in › · Move Up · Move Down ·
/// Share… · Export… · Delete.
///
/// Every item acts on the workspace ID it was built for and never selects that
/// workspace, so opening it from Settings doesn't page away.
@MainActor
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    private let workspaceId: UUID
    private weak var model: AppModel?
    private weak var presentingView: NSView?
    private let onRename: (UUID) -> Void
    /// Keeps each menu's target alive while its menu is open.
    private static var live: Set<WorkspaceMenu> = []
    /// NSColorPanel holds its target weakly.
    private static var colorPanelTarget: WorkspaceMenu?

    private init(workspaceId: UUID, model: AppModel, presentingView: NSView, onRename: @escaping (UUID) -> Void) {
        self.workspaceId = workspaceId
        self.model = model
        self.presentingView = presentingView
        self.onRename = onRename
    }

    private var workspace: Workspace? { model?.workspaces.first(id: workspaceId) }

    /// Builds the full menu for `workspaceId`. `onRename` starts the inline rename.
    static func make(for workspaceId: UUID, model: AppModel, presentingView: NSView, onRename: @escaping (UUID) -> Void) -> NSMenu {
        let handler = WorkspaceMenu(workspaceId: workspaceId, model: model, presentingView: presentingView, onRename: onRename)
        return handler.retained(handler.buildMenu())
    }

    /// Only the "Color" submenu, for a click on the workspace icon.
    static func makeColorMenu(for workspaceId: UUID, model: AppModel, presentingView: NSView) -> NSMenu {
        let handler = WorkspaceMenu(workspaceId: workspaceId, model: model, presentingView: presentingView, onRename: { _ in })
        return handler.retained(handler.colorSubmenu() ?? NSMenu())
    }

    /// Only the "Opens in" submenu, for the editor row and the sidebar row's chip.
    static func makeOpensInMenu(for workspaceId: UUID) -> NSMenu {
        OpensInMenu.make(current: OpensInStore().choice(for: workspaceId)) { choice in
            OpensInStore().set(choice, for: workspaceId)
        }
    }

    private func retained(_ menu: NSMenu) -> NSMenu {
        Self.live.insert(self)
        menu.delegate = self
        return menu
    }

    /// Actions are sent after the menu closes, so release on the next turn of the run loop.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { Self.live.remove(self) }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let model, workspace != nil else { return menu }
        let index = model.workspaces.firstIndex(id: workspaceId) ?? 0
        let count = model.workspaces.count

        menu.addItem(item("Rename", #selector(rename)))
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        color.submenu = colorSubmenu()
        menu.addItem(color)
        let icon = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        icon.submenu = iconSubmenu()
        menu.addItem(icon)
        let opensIn = NSMenuItem(title: "Opens in", action: nil, keyEquivalent: "")
        opensIn.submenu = Self.makeOpensInMenu(for: workspaceId)
        menu.addItem(opensIn)

        menu.addItem(.separator())
        let up = item("Move Up", #selector(moveUp))
        up.isEnabled = index > 0
        menu.addItem(up)
        let down = item("Move Down", #selector(moveDown))
        down.isEnabled = index < count - 1
        menu.addItem(down)

        menu.addItem(.separator())
        menu.addItem(item("Share…", #selector(share)))
        menu.addItem(item("Export…", #selector(export)))

        menu.addItem(.separator())
        let delete = item("Delete", #selector(delete))
        delete.isEnabled = count > 1
        if count <= 1 { delete.toolTip = "The only workspace can't be deleted" }
        menu.addItem(delete)
        return menu
    }

    private func iconSubmenu() -> NSMenu? {
        guard let workspace else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let favicons = item("Favicons", #selector(setIcon(_:)))
        favicons.representedObject = "favicons"
        favicons.state = workspace.icon == .favicons ? .on : .off
        let letter = item("Letter", #selector(setIcon(_:)))
        letter.representedObject = "letter"
        letter.state = workspace.icon == .letter ? .on : .off
        submenu.addItem(favicons)
        submenu.addItem(letter)
        let symbol = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "")
        let symbols = NSMenu()
        symbols.autoenablesItems = false
        for name in WorkspaceTileIdentity.symbols {
            let choice = item(name.replacingOccurrences(of: ".", with: " ").capitalized, #selector(setIcon(_:)))
            choice.representedObject = "symbol:" + name
            choice.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            if case .symbol(name) = workspace.icon { choice.state = .on }
            symbols.addItem(choice)
        }
        symbol.submenu = symbols
        if case .symbol = workspace.icon { symbol.state = .on }
        submenu.addItem(symbol)
        return submenu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func colorSubmenu() -> NSMenu? {
        guard let workspace else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for colorId in WorkspaceColorId.allCases {
            let item = item(colorId.name, #selector(changeColor(_:)))
            item.representedObject = colorId
            item.image = Self.dotImage(color: colorId.color)
            item.state = colorId == workspace.colorId ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let custom = item("Custom color…", #selector(chooseCustomColor))
        if case .custom = workspace.colorId { custom.state = .on }
        submenu.addItem(custom)
        return submenu
    }

    /// A 12pt dot with a 1pt ring, rendered per appearance when the menu draws.
    static func dotImage(color: NSColor, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            path.fill()
            SettingsColors.edge.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    // MARK: Actions

    @objc private func rename() {
        onRename(workspaceId)
    }

    @objc private func changeColor(_ sender: NSMenuItem) {
        guard let colorId = sender.representedObject as? WorkspaceColorId else { return }
        model?.updateWorkspaceColor(id: workspaceId, colorId: colorId)
    }

    @objc private func chooseCustomColor() {
        guard let workspace else { return }
        let panel = NSColorPanel.shared
        panel.color = workspace.colorId.color
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
        Self.colorPanelTarget = self
    }

    @objc private func customColorChanged(_ sender: Any?) {
        model?.updateWorkspaceColor(id: workspaceId, colorId: .custom(NSColorPanel.shared.color.hexString))
    }

    @objc private func setIcon(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let icon: WorkspaceIcon
        if value == "favicons" { icon = .favicons }
        else if value == "letter" { icon = .letter }
        else { icon = .symbol(String(value.dropFirst("symbol:".count))) }
        model?.updateWorkspaceIcon(id: workspaceId, icon: icon)
    }

    @objc private func share() {
        guard let model, let workspace else { return }
        do {
            SharePanel.show(url: try model.shareWorkspace(id: workspaceId), workspaceName: workspace.name)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Share failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func moveUp() {
        model?.moveWorkspace(id: workspaceId, direction: .left)
    }

    @objc private func moveDown() {
        model?.moveWorkspace(id: workspaceId, direction: .right)
    }

    @objc private func export() {
        guard let model, let workspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stow") ?? .json]
        panel.nameFieldStringValue = "\(workspace.name).stow"
        panel.canCreateDirectories = true
        let id = workspaceId
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try model.exportWorkspace(id: id).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window = presentingView?.window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    @objc private func delete() {
        guard let model else { return }
        WorkspaceDeletion.delete(workspaceId, model: model, in: presentingView?.window)
    }
}

/// The one delete path for workspaces: it deletes at once and shows an undo toast
/// (⌘Z works too), instead of asking first.
@MainActor
enum WorkspaceDeletion {
    static func itemCount(of workspace: Workspace) -> Int {
        func count(_ nodes: [Node]) -> Int {
            nodes.reduce(0) { total, node in
                if case .folder(let folder) = node { return total + count(folder.children) }
                return total + 1
            }
        }
        return count(workspace.items)
    }

    /// A deleted workspace that can still come back.
    @MainActor
    final class Pending {
        let workspace: Workspace
        let index: Int
        private weak var model: AppModel?
        private(set) var isOpen = true

        init(workspace: Workspace, index: Int, model: AppModel) {
            self.workspace = workspace
            self.index = index
            self.model = model
        }

        var message: String { "Deleted “\(workspace.name.isEmpty ? "Untitled" : workspace.name)”" }

        func undo() {
            guard isOpen else { return }
            isOpen = false
            model?.restoreWorkspace(workspace, at: index)
            CloudSyncManager.shared.scheduleLocalChanges()
        }

        /// The undo window closed: its favicons can go.
        func expire() {
            guard isOpen else { return }
            isOpen = false
            model?.cleanOrphanedFavicons()
        }
    }

    /// Deletes now and returns what an Undo needs, or nil for the only workspace.
    static func deleteUndoably(_ workspaceId: UUID, model: AppModel) -> Pending? {
        guard model.workspaces.count > 1, let index = model.workspaces.firstIndex(id: workspaceId) else { return nil }
        let pending = Pending(workspace: model.workspaces[index], index: index, model: model)
        model.deleteWorkspace(id: workspaceId, keepFavicons: true)
        return pending
    }

    /// Deletes and shows the undo toast at the bottom of `window`.
    static func delete(_ workspaceId: UUID, model: AppModel, in window: NSWindow?, onDeleted: (() -> Void)? = nil) {
        guard let pending = deleteUndoably(workspaceId, model: model) else { return }
        onDeleted?()
        window?.undoManager?.registerUndo(withTarget: pending) { pending in
            pending.undo()
            UndoToast.dismiss(expired: false)
        }
        window?.undoManager?.setActionName("Delete Workspace")
        UndoToast.show(pending.message, in: window, onUndo: { pending.undo() }, onExpire: { pending.expire() })
    }
}
