import AppKit
import StowShared

/// The list a workspace chip opens, the Tabline's and the rail's alike: "Workspaces", a
/// row per workspace (its colour dot, name, ✓ on the current one, ⌘1–9), then Edit
/// Workspace… and New workspace….
@MainActor
enum WorkspaceListFlyout {
    static let title = "Workspaces"

    static func sections(workspaces: [(id: UUID, name: String, colorId: WorkspaceColorId)], current: UUID?) -> [FlyoutListSection] {
        let rows = FlyoutListModel.rows(forWorkspaces: workspaces, current: current,
                                        shortcut: { WorkspaceShortcut.label(position: $0) })
        return [FlyoutListSection(title: nil, rows: rows)]
    }

    static func footer(edit: @escaping () -> Void, newWorkspace: @escaping () -> Void) -> [FlyoutListView.FooterButton] {
        [FlyoutListView.FooterButton(title: "Edit workspace…", action: edit),
         FlyoutListView.FooterButton(title: "New workspace…", action: newWorkspace)]
    }

    static func make(workspaces: [(id: UUID, name: String, colorId: WorkspaceColorId)], current: UUID?,
                     edit: @escaping () -> Void, newWorkspace: @escaping () -> Void) -> FlyoutListView {
        FlyoutListView(title: title, sections: sections(workspaces: workspaces, current: current),
                       footer: footer(edit: edit, newWorkspace: newWorkspace))
    }
}
