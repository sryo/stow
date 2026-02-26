import SwiftUI
import StowShared

struct WorkspaceOverviewSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = viewModel.refreshTrigger

        NavigationStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(viewModel.workspaces) { workspace in
                        WorkspaceCard(
                            workspace: workspace,
                            isSelected: workspace.id == viewModel.selectedWorkspaceId
                        ) {
                            viewModel.selectWorkspace(id: workspace.id)
                            dismiss()
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
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
            .background(Color(workspace.colorId.color).opacity(0.25))
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
