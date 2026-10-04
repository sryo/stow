import AppKit
import StowShared

/// The one right-click menu for an item, wherever it shows (list row, mosaic tile, rail
/// cell). Items that only change the library act through the model; the rest (rename,
/// editors, archive with its undo) go to the owner's `Actions`, since what they open
/// depends on where the menu was opened.
///
/// It stays a native NSMenu, like WorkspaceMenu, whose retained-handler pattern it follows.
@MainActor
final class NodeMenu: NSObject, NSMenuDelegate {
    struct Actions {
        var rename: (UUID) -> Void = { _ in }
        var editURL: (UUID) -> Void = { _ in }
        var setDueDate: (UUID) -> Void = { _ in }
        var editSnippet: (UUID) -> Void = { _ in }
        var copySnippet: (UUID) -> Void = { _ in }
        var openIn: (Link, OpensIn) -> Void = { _, _ in }
        var openFolder: (Folder) -> Void = { _ in }
        var newFolderInside: (UUID) -> Void = { _ in }
        var moveToNewWorkspace: ([UUID]) -> Void = { _ in }
        var moveToNewFolder: ([UUID]) -> Void = { _ in }
        var archive: (UUID) -> Void = { _ in }
        /// Where Copy link writes.
        var pasteboard: NSPasteboard = .general
    }

    /// Shown as hints for the list's keyboard shortcuts (F2, ⌘⌫).
    static let renameKey = String(Character(UnicodeScalar(NSF2FunctionKey)!))
    static let archiveKey = String(Character(UnicodeScalar(NSBackspaceCharacter)!))

    private let node: Node
    private weak var model: AppModel?
    private let actions: Actions
    /// Keeps each menu's target alive while its menu is open.
    private static var live: Set<NodeMenu> = []

    private init(node: Node, model: AppModel, actions: Actions) {
        self.node = node
        self.model = model
        self.actions = actions
    }

    static func make(for node: Node, model: AppModel, actions: Actions) -> NSMenu {
        let handler = NodeMenu(node: node, model: model, actions: actions)
        live.insert(handler)
        let menu = handler.buildMenu()
        menu.delegate = handler
        return menu
    }

    /// Actions are sent after the menu closes, so release on the next turn of the run loop.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { Self.live.remove(self) }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", mask: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = self
        return item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch node {
        case .folder(let folder):
            menu.addItem(item("New folder inside…", #selector(newFolderInside)))
            if !folder.children.flattenLinks().isEmpty {
                menu.addItem(item("Open all links", #selector(openFolder)))
            }
        case .link(let link):
            let openIn = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
            openIn.submenu = OpensInMenu.make(current: nil, includeBrowserImUsing: false) { [actions] choice in
                guard let choice else { return }
                actions.openIn(link, choice)
            }
            menu.addItem(openIn)
            menu.addItem(item("Copy link", #selector(copyLink)))
            menu.addItem(.separator())
            menu.addItem(item("Edit URL…", #selector(editURL)))
        case .task(let task):
            menu.addItem(item(task.isCompleted ? "Mark incomplete" : "Mark complete", #selector(toggleTask)))
            menu.addItem(item("Set due date…", #selector(setDueDate)))
            if task.dueDate != nil {
                menu.addItem(item("Clear due date", #selector(clearDueDate)))
            }
            menu.addItem(.separator())
        case .snippet:
            menu.addItem(item("Copy content", #selector(copySnippet)))
            menu.addItem(item("Edit snippet…", #selector(editSnippet)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Rename…", #selector(rename), key: Self.renameKey))
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        move.submenu = moveSubmenu()
        menu.addItem(move)
        menu.addItem(item("Archive", #selector(archive), key: Self.archiveKey, mask: .command))
        return menu
    }

    /// Every other workspace, then a new workspace or a new folder.
    private func moveSubmenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let home = model?.workspaces.first { $0.items.flattenIds().contains(node.id) }?.id
        let others = (model?.workspaces ?? []).filter { $0.id != home }
        for workspace in others {
            let entry = item(workspace.name, #selector(moveToWorkspace(_:)))
            entry.representedObject = workspace.id
            submenu.addItem(entry)
        }
        if !others.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item("New workspace…", #selector(moveToNewWorkspace)))
        submenu.addItem(item("New folder", #selector(moveToNewFolder)))
        return submenu
    }

    // MARK: Actions

    @objc private func rename() { actions.rename(node.id) }
    @objc private func archive() { actions.archive(node.id) }
    @objc private func editURL() { actions.editURL(node.id) }
    @objc private func setDueDate() { actions.setDueDate(node.id) }
    @objc private func editSnippet() { actions.editSnippet(node.id) }
    @objc private func copySnippet() { actions.copySnippet(node.id) }
    @objc private func newFolderInside() { actions.newFolderInside(node.id) }
    @objc private func moveToNewWorkspace() { actions.moveToNewWorkspace([node.id]) }
    @objc private func moveToNewFolder() { actions.moveToNewFolder([node.id]) }

    @objc private func openFolder() {
        if case .folder(let folder) = node { actions.openFolder(folder) }
    }

    @objc private func copyLink() {
        guard case .link(let link) = node else { return }
        actions.pasteboard.clearContents()
        actions.pasteboard.setString(link.url, forType: .string)
    }

    @objc private func toggleTask() { model?.toggleTaskCompletion(id: node.id) }
    @objc private func clearDueDate() { model?.updateTaskDueDate(id: node.id, dueDate: nil) }

    @objc private func moveToWorkspace(_ sender: NSMenuItem) {
        guard let workspaceId = sender.representedObject as? UUID else { return }
        model?.moveNodeToWorkspace(id: node.id, workspaceId: workspaceId)
    }
}
