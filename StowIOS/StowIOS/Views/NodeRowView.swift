import SwiftUI
import StowShared

struct NodeRowView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let node: Node
    let parentId: UUID?

    @State private var isEditing = false
    @State private var editText = ""
    @State private var snippetCopied = false
    @State private var showingDueDatePicker = false
    @State private var showingSnippetEditor = false

    var body: some View {
        let _ = viewModel.refreshTrigger

        switch node {
        case .folder(let folder):
            folderRow(folder)
        case .link(let link):
            linkRow(link)
        case .task(let task):
            taskRow(task)
        case .snippet(let snippet):
            snippetRow(snippet)
        }
    }

    // MARK: - Folder

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { folder.isExpanded },
                set: { viewModel.model.setFolderExpanded(id: folder.id, isExpanded: $0) }
            )
        ) {
            ForEach(folder.children, id: \.id) { child in
                NodeRowView(node: child, parentId: folder.id)
                    .environmentObject(viewModel)
            }
        } label: {
            nodeLabel(
                systemImage: "folder.fill",
                title: folder.name,
                tintColor: .orange,
                nodeId: folder.id
            )
        }
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Link

    @ViewBuilder
    private func linkRow(_ link: StowShared.Link) -> some View {
        Button {
            if let url = URL(string: link.url) {
                UIApplication.shared.open(url)
            }
        } label: {
            nodeLabel(
                systemImage: "globe",
                title: link.title,
                tintColor: .blue,
                nodeId: link.id
            )
        }
        .tint(.primary)
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Task

    @ViewBuilder
    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            viewModel.model.toggleTaskCompletion(id: task.id)
        } label: {
            nodeLabel(
                systemImage: task.isCompleted ? "checkmark.circle.fill" : "circle",
                title: task.title,
                tintColor: task.isCompleted ? .green : .secondary,
                nodeId: task.id,
                strikethrough: task.isCompleted
            )
        }
        .tint(.primary)
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Snippet

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        Button {
            UIPasteboard.general.string = snippet.content
            snippetCopied.toggle()
        } label: {
            nodeLabel(
                systemImage: "doc.text.fill",
                title: snippet.title,
                tintColor: .purple,
                nodeId: snippet.id
            )
        }
        .tint(.primary)
        .sensoryFeedback(.success, trigger: snippetCopied)
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Shared Label

    @ViewBuilder
    private func nodeLabel(
        systemImage: String,
        title: String,
        tintColor: Color,
        nodeId: UUID,
        strikethrough: Bool = false
    ) -> some View {
        if isEditing {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tintColor)
                    .frame(width: 20)
                TextField("Name", text: $editText)
                .onSubmit {
                    let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        viewModel.model.renameNode(id: nodeId, newName: trimmed)
                    }
                    isEditing = false
                }
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    editText = title
                }
            }
        } else {
            Label {
                Text(title)
                    .strikethrough(strikethrough)
                    .foregroundStyle(strikethrough ? .secondary : .primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tintColor)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for node: Node) -> some View {
        Button {
            editText = node.displayName
            isEditing = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button(role: .destructive) {
            viewModel.model.deleteNode(id: node.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }

        let otherWorkspaces = viewModel.workspaces.filter { $0.id != viewModel.selectedWorkspaceId }
        if !otherWorkspaces.isEmpty {
            Menu {
                ForEach(otherWorkspaces) { workspace in
                    Button(workspace.name) {
                        viewModel.model.moveNodeToWorkspace(id: node.id, workspaceId: workspace.id)
                    }
                }
            } label: {
                Label("Move to Workspace", systemImage: "arrow.right.square")
            }
        }
    }
}
