import SwiftUI
import StowShared

struct WorkspaceOverviewSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var renameWorkspaceId: UUID?
    @State private var renameText = ""
    @State private var deleteWorkspaceId: UUID?

    var body: some View {
        let _ = viewModel.refreshTrigger

        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.workspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                isSelected: workspace.id == viewModel.selectedWorkspaceId
                            ) {
                                viewModel.searchQuery = ""
                                viewModel.selectWorkspace(id: workspace.id)
                                dismiss()
                            }
                            .contextMenu {
                                Button {
                                    renameText = workspace.name
                                    renameWorkspaceId = workspace.id
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Menu {
                                    ForEach(WorkspaceColorId.allCases, id: \.name) { colorId in
                                        Button {
                                            viewModel.model.updateWorkspaceColor(id: workspace.id, colorId: colorId)
                                        } label: {
                                            Label {
                                                Text(colorId.name)
                                            } icon: {
                                                Image(systemName: workspace.colorId == colorId ? "circle.inset.filled" : "circle.fill")
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Color", systemImage: "paintpalette")
                                }

                                if let shareURL = try? viewModel.model.shareWorkspace(id: workspace.id) {
                                    ShareLink(item: shareURL) {
                                        Label("Share Link", systemImage: "square.and.arrow.up")
                                    }
                                }

                                if viewModel.workspaces.count > 1 {
                                    Divider()
                                    Button(role: .destructive) {
                                        if workspace.items.isEmpty {
                                            viewModel.deleteWorkspace(id: workspace.id)
                                        } else {
                                            deleteWorkspaceId = workspace.id
                                        }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        // "New Workspace" card
                        Button {
                            let id = viewModel.model.createWorkspace(name: "Untitled", colorId: .randomColor())
                            viewModel.selectedWorkspaceId = id
                            dismiss()
                        } label: {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
                                .frame(width: 200, height: 260)
                                .overlay {
                                    VStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.title)
                                            .foregroundStyle(.secondary)
                                        Text("New Workspace")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }

                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .alert("Rename Workspace", isPresented: Binding(
            get: { renameWorkspaceId != nil },
            set: { if !$0 { renameWorkspaceId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renameWorkspaceId = nil
            }
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renameWorkspaceId, !name.isEmpty {
                    viewModel.model.renameWorkspace(id: id, newName: name)
                }
                renameWorkspaceId = nil
            }
        }
        .confirmationDialog("Delete Workspace?", isPresented: Binding(
            get: { deleteWorkspaceId != nil },
            set: { if !$0 { deleteWorkspaceId = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteWorkspaceId {
                    viewModel.deleteWorkspace(id: id)
                }
                deleteWorkspaceId = nil
            }
        } message: {
            Text("This will permanently delete this workspace and all its contents.")
        }
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: Workspace
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text(workspace.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Divider()

                // First 4 items
                let items = Array(workspace.items.prefix(4))
                if items.isEmpty {
                    Text("No items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { node in
                            HStack(spacing: 6) {
                                Image(systemName: iconName(for: node))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(node.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .frame(width: 200, height: 260, alignment: .topLeading)
            .background(Color(uiColor: workspace.colorId.adaptiveBackgroundColor).opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func iconName(for node: Node) -> String {
        switch node {
        case .folder: return "folder.fill"
        case .link: return "globe"
        case .task(let task): return task.isCompleted ? "checkmark.circle.fill" : "circle"
        case .snippet: return "doc.text.fill"
        }
    }
}
