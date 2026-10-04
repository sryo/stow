import AppKit
import UniformTypeIdentifiers

/// The per-workspace menu used by Settings: Rename workspace · Change color › ·
/// Opens in › · Move up · Move down · Export workspace… · Delete workspace….
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

    /// Only the "Change color" submenu, for a click on the workspace icon.
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

        menu.addItem(item("Rename workspace", #selector(rename)))

        let color = NSMenuItem(title: "Change color", action: nil, keyEquivalent: "")
        color.submenu = colorSubmenu()
        menu.addItem(color)

        let opensIn = NSMenuItem(title: "Opens in", action: nil, keyEquivalent: "")
        opensIn.submenu = Self.makeOpensInMenu(for: workspaceId)
        menu.addItem(opensIn)

        menu.addItem(.separator())
        let up = item("Move up", #selector(moveUp))
        up.isEnabled = index > 0
        menu.addItem(up)
        let down = item("Move down", #selector(moveDown))
        down.isEnabled = index < count - 1
        menu.addItem(down)

        menu.addItem(.separator())
        menu.addItem(item("Export workspace…", #selector(export)))

        menu.addItem(.separator())
        let delete = item("Delete workspace…", #selector(delete))
        delete.isEnabled = count > 1
        if count <= 1 { delete.toolTip = "The only workspace can't be deleted" }
        menu.addItem(delete)
        return menu
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
        guard let model, let window = presentingView?.window else { return }
        WorkspaceDeletion.confirm(workspaceId, model: model, in: window)
    }
}

/// The one delete path for workspaces in Settings: always asks, naming the workspace and
/// how many items it holds. Cancel is the default button.
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

    static func confirm(_ workspaceId: UUID, model: AppModel, in window: NSWindow, onDeleted: (() -> Void)? = nil) {
        guard model.workspaces.count > 1, let workspace = model.workspaces.first(id: workspaceId) else { return }
        let count = itemCount(of: workspace)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if count > 0 {
            alert.messageText = "Delete “\(workspace.name)” and its \(count) \(count == 1 ? "item" : "items")?"
            alert.informativeText = "Its links, tasks and snippets will be removed. This can't be undone."
        } else if !workspace.items.isEmpty {
            alert.messageText = "Delete “\(workspace.name)”?"
            alert.informativeText = "Its empty folders will be removed. This can't be undone."
        } else {
            alert.messageText = "Delete “\(workspace.name)”?"
            alert.informativeText = "It's empty. This can't be undone."
        }
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            model.deleteWorkspace(id: workspaceId)
            onDeleted?()
        }
    }
}
