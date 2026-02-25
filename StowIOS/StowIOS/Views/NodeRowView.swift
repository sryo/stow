import SwiftUI
import StowShared

struct NodeRowView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let node: Node
    let parentId: UUID?

    @State private var isEditing = false
    @State private var editText = ""
    @State private var snippetCopied = false
    @State private var showCopiedToast = false
    @State private var showingDueDatePicker = false
    @State private var showingSnippetEditor = false

    var body: some View {
        let _ = viewModel.refreshTrigger

        Group {
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
        .sheet(isPresented: $showingDueDatePicker) {
            if case .task(let task) = node {
                DueDatePickerSheet(taskId: task.id)
                    .environmentObject(viewModel)
            }
        }
        .sheet(isPresented: $showingSnippetEditor) {
            if case .snippet(let snippet) = node {
                SnippetEditorSheet(snippetId: snippet.id, initialTitle: snippet.title, initialContent: snippet.content, initialLanguage: snippet.language)
                    .environmentObject(viewModel)
            }
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
        nodeLabel(
            systemImage: "globe",
            title: link.title,
            tintColor: .blue,
            nodeId: link.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: link.url) {
                UIApplication.shared.open(url)
            }
        }
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
        nodeLabel(
            systemImage: "doc.text.fill",
            title: snippet.language != nil ? "\(snippet.title) (\(snippet.language!))" : snippet.title,
            tintColor: .purple,
            nodeId: snippet.id
        )
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = snippet.content
            snippetCopied.toggle()
            withAnimation { showCopiedToast = true }
        }
        .overlay(alignment: .trailing) {
            if showCopiedToast {
                Text("Copied!")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .sensoryFeedback(.success, trigger: snippetCopied)
        .onChange(of: showCopiedToast) { _, showing in
            if showing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { showCopiedToast = false }
                }
            }
        }
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
        // Type-specific actions first
        switch node {
        case .folder(let folder):
            Button {
                viewModel.model.addFolder(name: "New Folder", parentId: folder.id)
            } label: {
                Label("New Folder Inside", systemImage: "folder.badge.plus")
            }

            let links = Self.collectLinks(from: folder.children)
            if !links.isEmpty {
                Button {
                    for urlString in links {
                        if let url = URL(string: urlString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } label: {
                    Label("Open All Links (\(links.count))", systemImage: "safari")
                }
            }

        case .link(let link):
            Button {
                UIPasteboard.general.string = link.url
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }

            if viewModel.model.canPinMore() {
                let isPinned = viewModel.currentWorkspace.pinnedLinks.contains { $0.id == link.id }
                if !isPinned {
                    Button {
                        viewModel.model.pinLink(id: link.id)
                    } label: {
                        Label("Pin", systemImage: "pin")
                    }
                } else {
                    Button {
                        viewModel.model.unpinLink(id: link.id)
                    } label: {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                }
            }

        case .task(let task):
            if task.dueDate == nil {
                Button {
                    showingDueDatePicker = true
                } label: {
                    Label("Set Due Date", systemImage: "calendar.badge.plus")
                }
            } else {
                Button {
                    viewModel.model.updateTaskDueDate(id: task.id, dueDate: nil)
                } label: {
                    Label("Clear Due Date", systemImage: "calendar.badge.minus")
                }
            }

        case .snippet(let snippet):
            Button {
                UIPasteboard.general.string = snippet.content
            } label: {
                Label("Copy Content", systemImage: "doc.on.doc")
            }

            Button {
                showingSnippetEditor = true
            } label: {
                Label("Edit Snippet", systemImage: "pencil.and.list.clipboard")
            }
        }

        Divider()

        // Common actions
        Button {
            editText = node.displayName
            isEditing = true
        } label: {
            Label("Rename", systemImage: "pencil")
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

        Divider()

        Button(role: .destructive) {
            viewModel.model.deleteNode(id: node.id)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private static func collectLinks(from nodes: [Node]) -> [String] {
        var urls: [String] = []
        for node in nodes {
            switch node {
            case .link(let link):
                urls.append(link.url)
            case .folder(let folder):
                urls.append(contentsOf: collectLinks(from: folder.children))
            default:
                break
            }
        }
        return urls
    }
}

// MARK: - Due Date Picker Sheet

struct DueDatePickerSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    let taskId: UUID
    @State private var selectedDate = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Due Date", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Set Due Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            viewModel.model.updateTaskDueDate(id: taskId, dueDate: selectedDate)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Snippet Editor Sheet

struct SnippetEditorSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    let snippetId: UUID
    @State private var title: String
    @State private var content: String
    @State private var language: String
    private let originalTitle: String

    private let languages = [
        "", "Swift", "Python", "JavaScript", "TypeScript", "Go", "Rust",
        "Java", "Kotlin", "C", "C++", "Ruby", "PHP", "HTML", "CSS",
        "SQL", "Shell", "Markdown", "JSON", "YAML"
    ]

    init(snippetId: UUID, initialTitle: String, initialContent: String, initialLanguage: String?) {
        self.snippetId = snippetId
        self.originalTitle = initialTitle
        _title = State(initialValue: initialTitle)
        _content = State(initialValue: initialContent)
        _language = State(initialValue: initialLanguage ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }

                Section("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang.isEmpty ? "None" : lang).tag(lang)
                        }
                    }
                }

                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle("Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedTitle.isEmpty && trimmedTitle != originalTitle {
                            viewModel.model.renameNode(id: snippetId, newName: trimmedTitle)
                        }
                        viewModel.model.updateSnippetContent(id: snippetId, content: content)
                        viewModel.model.updateSnippetLanguage(id: snippetId, language: language.isEmpty ? nil : language)
                        viewModel.model.autoDeriveTitleIfNeeded(id: snippetId)
                        dismiss()
                    }
                }
            }
        }
    }
}
