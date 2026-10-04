import AppKit
import UniformTypeIdentifiers

/// The one delete path for workspaces: it deletes at once and shows an undo toast
/// (⌘Z works too), instead of asking first.
@MainActor
enum WorkspaceDeletion {
    /// Deletes now and returns what an Undo needs, or nil for the only workspace.
    static func deleteUndoably(_ workspaceId: UUID, model: AppModel) -> PendingChange? {
        PendingChange.deleteWorkspace(workspaceId, model: model)
    }

    /// Deletes and shows the undo toast at the bottom of `window`.
    static func delete(_ workspaceId: UUID, model: AppModel, in window: NSWindow?, onDeleted: (() -> Void)? = nil) {
        guard let pending = deleteUndoably(workspaceId, model: model) else { return }
        onDeleted?()
        pending.offer(in: window)
    }
}

/// Export…: one workspace, with its favicons, to a .stow file the importer reads back.
@MainActor
enum WorkspaceExport {
    /// Asks where to save, as a sheet on `window` when there is one, then writes.
    static func run(_ workspaceId: UUID, model: AppModel, in window: NSWindow?) {
        guard let workspace = model.workspaces.first(where: { $0.id == workspaceId }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stow") ?? .json]
        panel.nameFieldStringValue = "\(workspace.name.isEmpty ? "Untitled" : workspace.name).stow"
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(workspaceId, model: model, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export failed"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    static func write(_ workspaceId: UUID, model: AppModel, to url: URL) throws {
        try model.exportWorkspace(id: workspaceId).write(to: url, options: .atomic)
    }
}

extension OpensInMenu {
    /// The "Opens in" choices for one workspace, for the editor's Opens in row.
    @MainActor
    static func make(forWorkspace workspaceId: UUID) -> NSMenu {
        make(current: OpensInStore().choice(for: workspaceId)) { choice in
            OpensInStore().set(choice, for: workspaceId)
        }
    }
}
