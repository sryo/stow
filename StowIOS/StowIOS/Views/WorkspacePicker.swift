import SwiftUI
import StowShared

struct WorkspacePicker: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        let _ = viewModel.refreshTrigger

        Menu {
            ForEach(viewModel.workspaces) { workspace in
                Button(action: { viewModel.selectWorkspace(id: workspace.id) }) {
                    Label(workspace.name, systemImage: "circle.fill")
                }
            }

            Divider()

            Button(action: { viewModel.createWorkspace(name: "New Workspace") }) {
                Label("New Workspace", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(viewModel.currentWorkspace.colorId.color))
                    .frame(width: 10, height: 10)
                Text(viewModel.currentWorkspace.name)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
