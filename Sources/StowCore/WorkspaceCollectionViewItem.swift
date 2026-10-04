import AppKit

/// Collection view item hosting a `WorkspaceRowView` for the Settings workspace list.
final class WorkspaceCollectionViewItem: NSCollectionViewItem {
    private var rowView: WorkspaceRowView?
    private(set) var workspaceId: UUID?

    struct Actions {
        var showMenu: (UUID, NSView) -> Void
        var showColorMenu: (UUID, NSView) -> Void
        var showProfileMenu: (UUID, NSView) -> Void
        var rename: (UUID) -> Void
        var commitRename: (UUID, String) -> Void
        var finishRename: (UUID) -> Void
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
        rowView.onShowMenu = { [weak self] anchor in self?.actions?.showMenu(id, anchor) }
        rowView.onShowColorMenu = { [weak self] anchor in self?.actions?.showColorMenu(id, anchor) }
        rowView.onShowProfileMenu = { [weak self] anchor in self?.actions?.showProfileMenu(id, anchor) }
        rowView.onRename = { [weak self] in self?.actions?.rename(id) }
        rowView.onDelete = { [weak self] in self?.actions?.delete(id) }
        rowView.onMove = { [weak self] direction in self?.actions?.move(id, direction) }
        var content = content
        if content.identity == nil { content.identity = WorkspaceTileIdentity.resolve([workspace])[workspace.id] }
        rowView.configure(content)
    }

    func beginInlineRename() {
        guard let id = workspaceId else { return }
        rowView?.beginInlineRename(
            onCommit: { [weak self] newName in
                self?.actions?.commitRename(id, newName)
                self?.actions?.finishRename(id)
            },
            onCancel: { [weak self] in
                self?.actions?.finishRename(id)
            }
        )
    }

    var isInlineRenaming: Bool {
        rowView?.isInlineRenaming ?? false
    }

    var row: WorkspaceRowView? { rowView }

    func refreshHoverState() {
        rowView?.refreshHoverState()
    }
}
