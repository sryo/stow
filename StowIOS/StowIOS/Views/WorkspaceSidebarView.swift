import SwiftUI
import StowShared

struct WorkspaceSidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedWorkspaceId },
            set: { id in
                if let id { viewModel.selectWorkspace(id: id) }
            }
        )) {
            ForEach(viewModel.workspaces) { workspace in
                WorkspaceRow(workspace: workspace)
                    .tag(workspace.id)
                    .editsWorkspaceOnLongPress { viewModel.editWorkspace(id: workspace.id) }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { viewModel.beginNewWorkspace() }) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Workspace")
            }
        }
    }
}
