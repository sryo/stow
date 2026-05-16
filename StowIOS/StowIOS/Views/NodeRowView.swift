import SwiftUI
import StowShared

struct NodeRowView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let node: Node
    let parentId: UUID?
    var isArchived: Bool = false

    @State private var isEditing = false
    @State private var editText = ""
    @State private var snippetCopied = false
    @State private var showCopiedCheck = false
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
            .onMove { indices, destination in
                guard let first = indices.first else { return }
                let nodeId = folder.children[first].id
                viewModel.model.moveNode(id: nodeId, toParentId: folder.id, index: destination)
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
        let domain: String? = link.displayDomain

        nodeLabel(
            systemImage: "globe",
            title: link.title,
            tintColor: .blue,
            nodeId: link.id,
            subtitle: domain
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
            if let url = URL(string: urlString) {
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
            withAnimation(.easeOut(duration: 0.15)) { showCopiedCheck = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.6)) { showCopiedCheck = false }
            }
        }
        .overlay(alignment: .trailing) {
            if showCopiedCheck {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .move(edge: .top))
                    ))
                    .padding(.trailing, 8)
            }
        }
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
        strikethrough: Bool = false,
        subtitle: String? = nil
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
                HStack(spacing: 6) {
                    Text(title)
                        .strikethrough(strikethrough)
                        .foregroundStyle(strikethrough ? .secondary : .primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
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
                    for raw in links {
                        let urlString = raw.contains("://") ? raw : "https://\(raw)"
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

        if isArchived {
            Button {
                viewModel.model.unarchiveNode(id: node.id)
            } label: {
                Label("Unarchive", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                viewModel.model.permanentlyDeleteNode(id: node.id)
            } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                viewModel.model.archiveNode(id: node.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    // MARK: - Helpers

    private static func collectLinks(from nodes: [Node]) -> [String] {
        nodes.flattenLinks().map { $0.url }
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
