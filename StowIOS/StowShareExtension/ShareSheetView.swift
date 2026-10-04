import SwiftUI
import StowShared

/// The share sheet: the link with its fetched title, a row of workspace chips with the last
/// opened workspace preselected, and Save. One tap saves to the default.
struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(model.title)
                                .font(.headline)
                                .lineLimit(2)
                                .accessibilityIdentifier("share.title")
                            if model.isFetchingTitle {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Text(model.host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.workspaces) { workspace in
                                WorkspaceChip(
                                    workspace: workspace,
                                    isSelected: workspace.id == model.selectedWorkspaceId
                                ) {
                                    model.selectedWorkspaceId = workspace.id
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Save to")
                }
            }
            .navigationTitle("Stow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        onSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(model.selectedWorkspaceId == nil || isSaving)
                }
            }
        }
        .task { await model.loadTitle() }
    }
}

private struct WorkspaceChip: View {
    let workspace: Workspace
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = StowTheme.colors(for: workspace.colorId)
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(uiColor: workspace.colorId.color))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(isSelected ? palette.ink.opacity(0.6) : Color.primary.opacity(0.15), lineWidth: isSelected ? 1 : 0.5))
                Text(workspace.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? palette.ink : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule().fill(isSelected ? Color(uiColor: palette.surface) : Color(uiColor: .tertiarySystemFill))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? palette.ink.opacity(0.25) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("share.chip")
    }
}
