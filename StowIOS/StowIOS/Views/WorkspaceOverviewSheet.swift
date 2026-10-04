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
    @State private var renameWorkspaceId: UUID?
    @State private var renameText = ""
    @State private var deleteWorkspaceId: UUID?
    @State private var showingSettings = false
    @State private var exportDocument: WorkspaceExportDocument?
    @State private var exportFilename = ""
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var transferErrorMessage: String?

    var body: some View {
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
                                                Image(uiImage: WorkspaceDotView.image(colorId, isCurrent: workspace.colorId == colorId))
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

                                Button {
                                    do {
                                        let data = try viewModel.model.exportWorkspace(id: workspace.id)
                                        exportDocument = WorkspaceExportDocument(data: data)
                                        exportFilename = workspace.name
                                        showingExporter = true
                                    } catch {
                                        transferErrorMessage = error.localizedDescription
                                    }
                                } label: {
                                    Label("Export File", systemImage: "square.and.arrow.down")
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
                            let id = viewModel.model.createWorkspace(name: "Untitled")
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
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: stowFileType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                transferErrorMessage = error.localizedDescription
            }
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
    @EnvironmentObject private var viewModel: AppViewModel
    let workspace: Workspace
    let isSelected: Bool

    private var background: UIColor { viewModel.background(for: workspace.colorId) }
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
            .background(Color(uiColor: background).opacity(0.25))
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
