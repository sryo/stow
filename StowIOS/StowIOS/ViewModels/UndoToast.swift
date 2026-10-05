import Foundation
import StowShared

/// A change that's already made and can still be taken back: an archived item or items,
/// an item deleted for good, a deleted workspace. The iPhone's copy of the Mac's
/// PendingChange, with the same messages.
@MainActor
final class PendingChange {
    let message: String
    let actionName: String
    private let revert: () -> Void
    private let finish: (() -> Void)?
    private(set) var isOpen = true

    /// `finish` runs when the toast times out (a delete's icon files can go) and closes the
    /// change for good. Without one, shake still undoes after the toast is gone.
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

    func expire() {
        guard isOpen, let finish else { return }
        isOpen = false
        finish()
    }

    /// “Name”, or “Untitled” for an empty one.
    static func quoted(_ name: String) -> String {
        "“\(name.isEmpty ? NodeDefaults.folderName : name)”"
    }

    static func archive(_ ids: [UUID], model: AppModel) -> PendingChange? {
        let nodes = ids.compactMap { model.nodeById($0) }.filter { !$0.isArchived }
        guard !nodes.isEmpty else { return nil }
        for node in nodes { model.archiveNode(id: node.id) }
        let message = nodes.count == 1 ? "Archived \(quoted(nodes[0].displayName))" : "Archived \(nodes.count) items"
        return PendingChange(message: message, actionName: "Archive") { [weak model] in
            for node in nodes { model?.unarchiveNode(id: node.id) }
        }
    }

    static func deletePermanently(_ id: UUID, model: AppModel) -> PendingChange? {
        guard let removed = model.permanentlyDeleteNode(id: id, keepFavicons: true) else { return nil }
        return PendingChange(message: "Deleted \(quoted(removed.node.displayName))", actionName: "Delete",
                             revert: { [weak model] in model?.restoreNode(removed) },
                             finish: { [weak model] in model?.cleanOrphanedFavicons() })
    }

    /// Deletes the workspace now; nil for the only workspace.
    static func deleteWorkspace(_ workspaceId: UUID, model: AppModel) -> PendingChange? {
        guard model.workspaces.count > 1, let index = model.workspaces.firstIndex(where: { $0.id == workspaceId })
        else { return nil }
        let workspace = model.workspaces[index]
        model.deleteWorkspace(id: workspaceId, keepFavicons: true)
        return PendingChange(message: "Deleted \(quoted(workspace.name))", actionName: "Delete Workspace",
                             revert: { [weak model] in model?.restoreWorkspace(workspace, at: index) },
                             finish: { [weak model] in model?.cleanOrphanedFavicons() })
    }
}

/// The one Undo toast at the bottom of the screen. A new change replaces (and closes) the
/// one showing; each also goes on the shake-to-undo stack.
@MainActor
final class UndoToastCenter: ObservableObject {
    static let duration: TimeInterval = 6

    @Published private(set) var current: PendingChange?
    private let duration: TimeInterval
    private weak var undoManager: UndoManager?
    private var timer: Task<Void, Never>?

    init(duration: TimeInterval = UndoToastCenter.duration) {
        self.duration = duration
    }

    func offer(_ change: PendingChange, undoManager: UndoManager?) {
        expire()
        current = change
        if let undoManager {
            self.undoManager = undoManager
            // UndoManager doesn't retain its target; the handler keeps the change alive.
            undoManager.registerUndo(withTarget: change) { [weak self] change in
                change.undo()
                if self?.current === change { self?.dismiss() }
            }
            undoManager.setActionName(change.actionName)
        }
        timer = Task { [weak self, duration] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.current === change else { return }
            self.expire()
        }
    }

    /// The toast's Undo button.
    func undo() {
        guard let change = current else { return }
        change.undo()
        undoManager?.removeAllActions(withTarget: change)
        dismiss()
    }

    /// The toast timed out or was replaced.
    func expire() {
        current?.expire()
        dismiss()
    }

    private func dismiss() {
        timer?.cancel()
        timer = nil
        current = nil
    }
}

/// Archive and delete for items, each with an Undo toast.
@MainActor
enum ItemUndo {
    @discardableResult
    static func archive(_ ids: [UUID], model: AppModel, toasts: UndoToastCenter, undoManager: UndoManager?) -> Bool {
        guard let change = PendingChange.archive(ids, model: model) else { return false }
        toasts.offer(change, undoManager: undoManager)
        return true
    }

    @discardableResult
    static func deletePermanently(_ id: UUID, model: AppModel, toasts: UndoToastCenter, undoManager: UndoManager?) -> Bool {
        guard let change = PendingChange.deletePermanently(id, model: model) else { return false }
        toasts.offer(change, undoManager: undoManager)
        return true
    }
}

/// Deleting a workspace goes at once, with an Undo toast, as on the Mac.
@MainActor
enum WorkspaceDeletion {
    @discardableResult
    static func delete(_ workspaceId: UUID, model: AppModel, toasts: UndoToastCenter, undoManager: UndoManager?) -> Bool {
        guard let change = PendingChange.deleteWorkspace(workspaceId, model: model) else { return false }
        toasts.offer(change, undoManager: undoManager)
        return true
    }
}
