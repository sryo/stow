import AppKit

/// Collection view item hosting a `WorkspaceRowView` for the Settings workspace list.
final class WorkspaceCollectionViewItem: NSCollectionViewItem {
    private var rowView: WorkspaceRowView?
    private(set) var workspaceId: UUID?

    struct Actions {
        /// Open the workspace editor beside this row.
        var edit: (UUID, NSView) -> Void
        /// Show the WorkspaceMenu at this row.
        var contextMenu: (UUID, NSView) -> Void
        var delete: (UUID) -> Void
        var move: (UUID, WorkspaceMoveDirection) -> Void
    }

    private var actions: Actions?

    override func loadView() {
        let row = WorkspaceRowView(frame: .zero)
        self.view = row
        self.rowView = row
    }

    // Selection exists only to enable drag and drop; it isn't drawn.
    override var isSelected: Bool {
        didSet {}
    }

    func configure(workspace: Workspace, content: WorkspaceRowView.Content, actions: Actions) {
        workspaceId = workspace.id
        self.actions = actions
        guard let rowView else { return }
        let id = workspace.id
        rowView.onEdit = { [weak self, weak rowView] in
            guard let rowView else { return }
            self?.actions?.edit(id, rowView)
        }
        rowView.onContextMenu = { [weak self, weak rowView] in
            guard let rowView else { return }
            self?.actions?.contextMenu(id, rowView)
        }
        rowView.onDelete = { [weak self] in self?.actions?.delete(id) }
        rowView.onMove = { [weak self] direction in self?.actions?.move(id, direction) }
        var content = content
        if content.identity == nil { content.identity = WorkspaceTileIdentity.resolve([workspace])[workspace.id] }
        rowView.configure(content)
    }

    var row: WorkspaceRowView? { rowView }

    func refreshHoverState() {
        rowView?.refreshHoverState()
    }
}
