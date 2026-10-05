import SwiftUI
import StowShared

/// Bottom-anchored action bar shown when the iOS list is in edit mode and at
/// least one node is selected. Mirrors the Mac bulk actions in
/// `NodeListViewController.bulk*` selectors.
struct BulkActionBar: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.undoManager) private var undoManager

    @State private var showingMoveTarget = false
    @State private var showingNewFolderPrompt = false
    @State private var newFolderName = ""

    private var selectedIds: Set<UUID> { viewModel.selectedNodeIds }

    private var selectedLinks: [StowShared.Link] {
        viewModel.currentWorkspace.items.flattenLinks().filter { selectedIds.contains($0.id) }
    }

    private func done() { viewModel.clearSelection() }

    var body: some View {
        HStack(spacing: 0) {
            actionButton(label: "Open", systemImage: "safari", disabled: selectedLinks.isEmpty) {
                for link in selectedLinks {
                    let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
                    if let url = URL(string: urlString) {
                        UIApplication.shared.open(url)
                    }
                }
                done()
            }
            actionButton(label: "Copy", systemImage: "doc.on.doc", disabled: selectedLinks.isEmpty) {
                UIPasteboard.general.string = selectedLinks.map(\.url).joined(separator: "\n")
                done()
            }
            actionButton(label: "Group", systemImage: "folder.badge.plus") {
                newFolderName = "New Folder"
                showingNewFolderPrompt = true
            }
            actionButton(label: "Move", systemImage: "arrow.up.bin") {
                showingMoveTarget = true
            }
            actionButton(label: "Archive", systemImage: "archivebox", role: .destructive) {
                viewModel.archive(Array(selectedIds), undoManager: undoManager)
                done()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .confirmationDialog("Move to workspace", isPresented: $showingMoveTarget, titleVisibility: .visible) {
            ForEach(viewModel.workspaces.filter { $0.id != viewModel.selectedWorkspaceId }) { ws in
                Button(ws.name) {
                    viewModel.model.moveNodesToWorkspace(nodeIds: Array(selectedIds), toWorkspaceId: ws.id)
                    done()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $showingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Group") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                viewModel.model.groupNodesInNewFolder(nodeIds: Array(selectedIds), folderName: trimmed)
                done()
            }
        } message: {
            Text("Wrap the selected items in a new folder.")
        }
    }

    @ViewBuilder
    private func actionButton(
        label: String,
        systemImage: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }
}
