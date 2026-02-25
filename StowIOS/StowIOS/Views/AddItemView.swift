import SwiftUI
import StowShared

struct AddItemView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss

    enum ItemType: String, CaseIterable, Identifiable {
        case link = "Link"
        case folder = "Folder"
        case task = "Task"
        case snippet = "Snippet"

        var id: String { rawValue }
    }

    @State private var selectedType: ItemType = .link
    @State private var name = ""
    @State private var urlString = ""
    @State private var snippetContent = ""
    @State private var snippetLanguage = ""

    private let languages = [
        "", "Swift", "Python", "JavaScript", "TypeScript", "Go", "Rust",
        "Java", "Kotlin", "C", "C++", "Ruby", "PHP", "HTML", "CSS",
        "SQL", "Shell", "Markdown", "JSON", "YAML"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $selectedType) {
                        ForEach(ItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                switch selectedType {
                case .link:
                    linkFields
                case .folder:
                    folderFields
                case .task:
                    taskFields
                case .snippet:
                    snippetFields
                }
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addItem()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Field Sections

    @ViewBuilder
    private var linkFields: some View {
        Section("Link Details") {
            TextField("URL", text: $urlString)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            TextField("Title (optional)", text: $name)
        }
    }

    @ViewBuilder
    private var folderFields: some View {
        Section("Folder Details") {
            TextField("Name", text: $name)
        }
    }

    @ViewBuilder
    private var taskFields: some View {
        Section("Task Details") {
            TextField("Title", text: $name)
        }
    }

    @ViewBuilder
    private var snippetFields: some View {
        Section("Snippet Details") {
            TextField("Title", text: $name)
            Picker("Language", selection: $snippetLanguage) {
                ForEach(languages, id: \.self) { lang in
                    Text(lang.isEmpty ? "None" : lang).tag(lang)
                }
            }
        }

        Section("Content") {
            TextEditor(text: $snippetContent)
                .frame(minHeight: 120)
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        switch selectedType {
        case .link:
            return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .folder:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .task:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .snippet:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Actions

    private func addItem() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        switch selectedType {
        case .link:
            let title = trimmedName.isEmpty ? trimmedUrl : trimmedName
            viewModel.model.addLink(urlString: trimmedUrl, title: title, parentId: nil)
        case .folder:
            viewModel.model.addFolder(name: trimmedName, parentId: nil)
        case .task:
            viewModel.model.addTask(title: trimmedName, parentId: nil)
        case .snippet:
            let language: String? = snippetLanguage.isEmpty ? nil : snippetLanguage
            viewModel.model.addSnippet(
                title: trimmedName,
                content: snippetContent,
                language: language,
                parentId: nil
            )
        }
    }
}
