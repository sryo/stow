import SwiftUI
import StowShared

struct NodeRowView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.stowColors) private var colors
    let node: Node
    let parentId: UUID?
    var isArchived: Bool = false

    @State private var isEditing = false
    @State private var editText = ""
    @State private var snippetCopied = false
    @State private var showCopiedCheck = false
    @State private var showingDueDatePicker = false
    @State private var showingSnippetEditor = false
    @State private var showingLinkURLEditor = false
    @State private var favicon: UIImage?

    var body: some View {
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
        .sheet(isPresented: $showingLinkURLEditor) {
            if case .link(let link) = node {
                LinkURLEditorSheet(linkId: link.id, initialURL: link.url)
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
                systemImage: folder.isExpanded ? "folder" : "folder.fill",
                title: folder.name,
                nodeId: folder.id,
                meta: folder.children.isEmpty ? nil : "\(folder.children.count)",
                emphasized: true
            )
        }
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Link

    @ViewBuilder
    private func linkRow(_ link: StowShared.Link) -> some View {
        let domain: String? = link.displayDomain

        nodeLabel(
            systemImage: "link",
            title: link.title,
            nodeId: link.id,
            meta: domain,
            iconImage: favicon
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
            if let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
        .contextMenu { contextMenuItems(for: node) }
        .onAppear { loadFavicon(for: link) }
    }

    private func loadFavicon(for link: StowShared.Link) {
        let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
        guard let url = URL(string: urlString) else { return }
        FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { image, path in
            favicon = image
            if let path, path != link.faviconPath {
                viewModel.model.updateLinkFaviconPath(id: link.id, path: path)
            }
        }
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
                nodeId: task.id,
                strikethrough: task.isCompleted,
                meta: task.dueDate.map { Self.dueFormatter.string(from: $0) },
                metaIsOverdue: !task.isCompleted && (task.dueDate.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false)
            )
        }
        .tint(colors.ink)
        .contextMenu { contextMenuItems(for: node) }
    }

    // MARK: - Snippet

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        nodeLabel(
            systemImage: "chevron.left.forwardslash.chevron.right",
            title: snippet.title,
            nodeId: snippet.id,
            badge: snippet.language
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
                    .foregroundStyle(colors.ink)
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

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    @ViewBuilder
    private func nodeLabel(
        systemImage: String,
        title: String,
        nodeId: UUID,
        strikethrough: Bool = false,
        meta: String? = nil,
        metaIsOverdue: Bool = false,
        badge: String? = nil,
        emphasized: Bool = false,
        iconImage: UIImage? = nil
    ) -> some View {
        if isEditing {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(colors.inkSoft)
                    .frame(width: 22)
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
            HStack(spacing: 12) {
                Group {
                    if let iconImage {
                        Image(uiImage: iconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: systemImage)
                            .font(.body.weight(.medium))
                            .foregroundStyle(colors.inkSoft)
                    }
                }
                .frame(width: 22)
                .accessibilityHidden(true)

                Text(title)
                    .fontWeight(emphasized ? .semibold : .regular)
                    .strikethrough(strikethrough)
                    .foregroundStyle(strikethrough ? colors.inkSoft : colors.ink)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(colors.inkSoft)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(colors.strokeColor, lineWidth: 1))
                        .lineLimit(1)
                } else if let meta {
                    Text(metaIsOverdue ? "! " + meta : meta)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(metaIsOverdue ? colors.overdueColor : colors.inkSoft)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
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

            Button {
                showingLinkURLEditor = true
            } label: {
                Label("Edit URL", systemImage: "pencil")
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

// MARK: - Link URL Editor Sheet

struct LinkURLEditorSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    let linkId: UUID
    @State private var urlText: String

    init(linkId: UUID, initialURL: String) {
        self.linkId = linkId
        _urlText = State(initialValue: initialURL)
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("https://example.com", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.model.updateLinkUrl(id: linkId, newUrl: trimmedURL)
                        dismiss()
                    }
                    .disabled(trimmedURL.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
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
