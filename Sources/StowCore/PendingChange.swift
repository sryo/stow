import AppKit

/// A change that's already made and can still be taken back: a deleted workspace, an
/// archived item or items, an item deleted for good. `offer(in:)` puts it on Edit ▸ Undo
/// (⌘Z) and shows the toast with an Undo button.
@MainActor
final class PendingChange {
    let message: String
    let actionName: String
    private let revert: () -> Void
    private let finish: (() -> Void)?
    private(set) var isOpen = true
    private var toast: Toast.Token?
    private weak var undoManager: UndoManager?

    /// `finish` runs when the toast times out (a delete's icon files can go) and closes
    /// the change for good. Without one, ⌘Z still undoes after the toast is gone.
    init(message: String, actionName: String, revert: @escaping () -> Void, finish: (() -> Void)? = nil) {
        self.message = message
        self.actionName = actionName
        self.revert = revert
        self.finish = finish
    }

    func undo() {
        guard isOpen else { return }
        isOpen = false
        revert()
    }

    /// The toast timed out or was replaced.
    func expire() {
        guard isOpen, let finish else { return }
        isOpen = false
        finish()
    }

    /// Registers the undo on `window`'s undo manager and shows the toast at its bottom.
    func offer(in window: NSWindow?) {
        if let undoManager = window?.undoManager {
            self.undoManager = undoManager
            undoManager.registerUndo(withTarget: self) { change in
                change.undo()
                Toast.dismiss(change.toast, expired: false)
            }
            undoManager.setActionName(actionName)
        }
        toast = Toast.show(message, action: .undo { [self] in
            undo()
            undoManager?.removeAllActions(withTarget: self)
        }, in: window, onExpire: { [self] in expire() })
    }

    /// “Name”, or “Untitled” for an empty one.
    private static func quoted(_ name: String) -> String {
        "“\(name.isEmpty ? NodeDefaults.folderName : name)”"
    }

    // MARK: - Nodes

    /// Archives the items now (those not archived already); nil when there's nothing to do.
    static func archive(_ ids: [UUID], model: AppModel) -> PendingChange? {
        let nodes = ids.compactMap { model.nodeById($0) }.filter { !$0.isArchived }
        guard !nodes.isEmpty else { return nil }
        for node in nodes { model.archiveNode(id: node.id) }
        let message = nodes.count == 1 ? "Archived \(quoted(nodes[0].displayName))" : "Archived \(nodes.count) items"
        return PendingChange(message: message, actionName: "Archive") { [weak model] in
            for node in nodes { model?.unarchiveNode(id: node.id) }
        }
    }

    /// Deletes the item for good now, keeping what an undo needs until the toast is gone.
    static func deletePermanently(_ id: UUID, model: AppModel) -> PendingChange? {
        guard let removed = model.permanentlyDeleteNode(id: id, keepFavicons: true) else { return nil }
        return PendingChange(message: "Deleted \(quoted(removed.node.displayName))", actionName: "Delete",
                             revert: { [weak model] in model?.restoreNode(removed) },
                             finish: { [weak model] in model?.cleanOrphanedFavicons() })
    }

    // MARK: - Workspaces

    /// Deletes the workspace now; nil for the only workspace.
    static func deleteWorkspace(_ workspaceId: UUID, model: AppModel) -> PendingChange? {
        guard model.workspaces.count > 1, let index = model.workspaces.firstIndex(id: workspaceId) else { return nil }
        let workspace = model.workspaces[index]
        model.deleteWorkspace(id: workspaceId, keepFavicons: true)
        return PendingChange(message: "Deleted \(quoted(workspace.name))", actionName: "Delete Workspace",
                             revert: { [weak model] in
                                 model?.restoreWorkspace(workspace, at: index)
                                 CloudSyncManager.shared.scheduleLocalChanges()
                             },
                             finish: { [weak model] in model?.cleanOrphanedFavicons() })
    }
}
