import SwiftUI
import StowShared

struct WorkspaceRow: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceBadge(colorId: workspace.colorId, identity: viewModel.workspaceIdentities[workspace.id], size: 24)
            Text(workspace.name)
                .lineLimit(1)
        }
    }
}
