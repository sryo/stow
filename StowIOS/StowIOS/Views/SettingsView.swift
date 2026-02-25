import SwiftUI
import StowShared

struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        let _ = viewModel.refreshTrigger

        NavigationStack {
            Form {
                Section("Workspaces") {
                    ForEach(viewModel.workspaces) { workspace in
                        NavigationLink(destination: WorkspaceSettingsView(workspaceId: workspace.id)) {
                            WorkspaceRow(workspace: workspace)
                        }
                    }

                    Button(action: { viewModel.createWorkspace(name: "New Workspace") }) {
                        Label("Add Workspace", systemImage: "plus")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
