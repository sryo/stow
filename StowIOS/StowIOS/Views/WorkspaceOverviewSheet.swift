import SwiftUI
import UniformTypeIdentifiers
import StowShared

/// `.stow` isn't declared in Info.plist, so this resolves to a dynamic type —
/// enough for the exporter to name files and for round-tripping our own files.
let stowFileType = UTType(filenameExtension: "stow", conformingTo: .json) ?? .json

struct WorkspaceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [stowFileType] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct WorkspaceOverviewSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingSettings = false
    @State private var showingImporter = false
    @State private var transferErrorMessage: String?
    /// The Edit Workspace sheet, on top of this one.
    @State private var editor: WorkspaceEditorModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.workspaces) { workspace in
                            WorkspaceCard(
                                workspace: workspace,
                                isSelected: workspace.id == viewModel.selectedWorkspaceId,
                                onTap: {
                                    viewModel.searchQuery = ""
                                    viewModel.selectWorkspace(id: workspace.id)
                                    dismiss()
                                },
                                onEdit: {
                                    editor = WorkspaceEditorModel(editing: workspace.id, in: viewModel.model)
                                }
                            )
                        }

                        // "New Workspace" card
                        Button {
                            editor = WorkspaceEditorModel(creatingIn: viewModel.model)
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
                        .accessibilityIdentifier("workspaces.new")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }

                Button {
                    showingImporter = true
                } label: {
                    Label("Import Workspace…", systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                .padding(.bottom, 8)

                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .undoToast(viewModel.undoToasts)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .sheet(item: $editor, onDismiss: {
            // A new workspace opens: this sheet steps aside for it, as a tap on a card does.
            if editor?.createdId != nil { dismiss() }
        }) { editor in
            WorkspaceEditorSheet(editor: editor, onOpen: { dismiss() })
                .environmentObject(viewModel)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let id = try viewModel.model.importWorkspace(from: data)
                    viewModel.selectedWorkspaceId = id
                } catch {
                    transferErrorMessage = error.localizedDescription
                }
            case .failure(let error):
                transferErrorMessage = error.localizedDescription
            }
        }
        .alert("Transfer Failed", isPresented: Binding(
            get: { transferErrorMessage != nil },
            set: { if !$0 { transferErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferErrorMessage ?? "")
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let workspace: Workspace
    let isSelected: Bool

    private var background: UIColor { viewModel.background(for: workspace.colorId) }
    let onTap: () -> Void
    let onEdit: () -> Void

    /// Tap goes to the workspace; long-press edits it.
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    WorkspaceBadge(colorId: workspace.colorId, identity: viewModel.workspaceIdentities[workspace.id], size: 28)
                    Text(workspace.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

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
            .background(Color(uiColor: background).opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: onTap)
        .editsWorkspaceOnLongPress(onEdit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workspace.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("workspace.card")
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
