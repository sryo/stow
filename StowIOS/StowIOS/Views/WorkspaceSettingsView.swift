import SwiftUI
import StowShared

struct WorkspaceSettingsView: View {
    let workspaceId: UUID
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var workspaceName: String = ""
    @State private var showDeleteConfirmation = false

    private var workspace: Workspace? {
        viewModel.workspaces.first { $0.id == workspaceId }
    }

    var body: some View {
        let _ = viewModel.refreshTrigger

        Form {
            Section("Name") {
                TextField("Workspace Name", text: $workspaceName)
                    .onSubmit {
                        viewModel.model.renameWorkspace(id: workspaceId, newName: workspaceName)
                    }
            }

            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                    ForEach(WorkspaceColorId.allCases, id: \.name) { colorId in
                        Button(action: {
                            viewModel.model.updateWorkspaceColor(id: workspaceId, colorId: colorId)
                        }) {
                            Circle()
                                .fill(Color(colorId.color))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if workspace?.colorId == colorId {
                                        Image(systemName: "checkmark")
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }

            if viewModel.workspaces.count > 1 {
                Section {
                    Button("Delete Workspace", role: .destructive) {
                        let isEmpty = workspace?.items.isEmpty ?? true
                        if isEmpty {
                            viewModel.deleteWorkspace(id: workspaceId)
                            dismiss()
                        } else {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
        }
        .navigationTitle("Edit Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            workspaceName = workspace?.name ?? ""
        }
        .confirmationDialog("Delete Workspace?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                viewModel.deleteWorkspace(id: workspaceId)
                dismiss()
            }
        } message: {
            Text("This will permanently delete this workspace and all its contents.")
        }
    }
}
