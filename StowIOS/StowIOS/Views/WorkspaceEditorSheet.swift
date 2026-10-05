import SwiftUI
import UIKit
import StowShared

/// The one Edit Workspace sheet, reached by long-pressing any workspace (a card in the
/// Workspaces sheet, a page's title, an iPad sidebar row) and by every "new workspace".
/// Same fields, order and labels as the Mac's editor: name, Color, Icon, then Open,
/// Share…, Export… and Delete.
struct WorkspaceEditorSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @ObservedObject var editor: WorkspaceEditorModel
    /// Runs after Open selects the workspace, so the presenter can get out of the way.
    var onOpen: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @FocusState private var nameFocused: Bool
    @State private var exportDocument: WorkspaceExportDocument?
    @State private var showingExporter = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    colorSection
                    iconSection
                    if !editor.isNew { actions }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle(editor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard editor.focusesName else { return }
            // The field can only take focus once the sheet is on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nameFocused = true }
        }
        .onDisappear { editor.finish() }
        .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: stowFileType,
                      defaultFilename: editor.name) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Transfer Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            WorkspaceBadge(colorId: editor.colorId, identity: editor.preview, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Workspace name", text: $editor.name)
                    .font(.title3.weight(.semibold))
                    .textInputAutocapitalization(.words)
                    .submitLabel(editor.isNew ? .done : .return)
                    .focused($nameFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("editor.name")
                if !editor.isNew {
                    Text("\(editor.itemCount) \(editor.itemCount == 1 ? "item" : "items")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Color")
            HStack(spacing: 0) {
                ForEach(WorkspaceEditorModel.presetColors, id: \.self) { preset in
                    Button {
                        editor.chooseColor(preset)
                    } label: {
                        WorkspaceDotView(colorId: preset, diameter: 26, isCurrent: editor.colorId == preset)
                            .padding(editor.colorId == preset ? 0 : WorkspaceDotView.ringOutset)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(editor.colorId == preset ? .isSelected : [])
                }
                ColorPicker("Custom color…", selection: Binding(
                    get: { Color(uiColor: editor.colorId.color) },
                    set: { editor.setCustomColor(UIColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .padding(3)
                .overlay {
                    if editor.isCustomColor {
                        Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Custom color…")
                .accessibilityAddTraits(editor.isCustomColor ? .isSelected : [])
            }
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Icon")
            HStack(spacing: 8) {
                ForEach(WorkspaceEditorModel.iconChoices, id: \.title) { choice in
                    let chosen = editor.isChosen(choice)
                    Button {
                        editor.chooseIcon(choice.style)
                    } label: {
                        VStack(spacing: 6) {
                            WorkspaceBadge(colorId: editor.colorId, identity: editor.preview(for: choice), size: 30)
                            Text(choice.title)
                                .font(.caption.weight(chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(chosen ? Color.primary : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.title) icon")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            if case .symbol = editor.icon {
                HStack(spacing: 0) {
                    ForEach(WorkspaceEditorModel.symbols, id: \.self) { symbol in
                        let chosen = editor.selectedSymbol == symbol
                        Button {
                            editor.chooseSymbol(symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(chosen ? .primary : .secondary)
                                .frame(width: 36, height: 32)
                                .background(chosen ? Color(uiColor: .tertiarySystemFill) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Divider()
            // One row while the four fit unbroken; with larger text, a full-width button each.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openButton.fixedSize()
                    shareButton.fixedSize()
                    exportButton.fixedSize()
                    Spacer(minLength: 0)
                    deleteButton.fixedSize()
                }
                VStack(spacing: 8) {
                    openButton.frame(maxWidth: .infinity)
                    shareButton.frame(maxWidth: .infinity)
                    exportButton.frame(maxWidth: .infinity)
                    deleteButton.frame(maxWidth: .infinity)
                }
            }
            .controlSize(.regular)
            if !editor.canDelete {
                Text("The only workspace can't be deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var openButton: some View {
        Button {
            editor.open()
            dismiss()
            onOpen()
        } label: {
            Text("Open").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder private var shareButton: some View {
        if let url = editor.shareURL {
            ShareLink(item: url) { Text("Share…").lineLimit(1).frame(maxWidth: .infinity) }
                .buttonStyle(.bordered)
        }
    }

    private var exportButton: some View {
        Button {
            do {
                exportDocument = WorkspaceExportDocument(data: try editor.exportData())
                showingExporter = true
            } catch {
                exportError = error.localizedDescription
            }
        } label: {
            Text("Export…").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if editor.delete(toasts: viewModel.undoToasts, undoManager: undoManager) { dismiss() }
        } label: {
            Text("Delete").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!editor.canDelete)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editor.isNew {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    editor.cancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: submit)
                    .fontWeight(.semibold)
                    .disabled(!editor.canCommit)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }

    /// Return: a new workspace is created (once it has a name); an edited one is done.
    private func submit() {
        if editor.isNew {
            guard editor.commit() != nil else { return }
            viewModel.searchQuery = ""
        }
        dismiss()
    }
}

extension View {
    /// Long-press opens the workspace's Edit Workspace sheet; taps are left to the view.
    func editsWorkspaceOnLongPress(_ edit: @escaping () -> Void) -> some View {
        onLongPressGesture(minimumDuration: 0.4) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            edit()
        }
        .accessibilityAction(named: "Edit…", edit)
    }
}
