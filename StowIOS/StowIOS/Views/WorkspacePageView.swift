import SwiftUI
import StowShared

struct WorkspacePageView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Binding var showingOverview: Bool
    @State private var scrollOffset: CGFloat = 0
    @State private var showingEmptyClipboard = false
    @State private var showingAddItem = false

    var body: some View {
        let _ = viewModel.refreshTrigger
        let workspaces = viewModel.workspaces

        WorkspacePagerRepresentable(
            workspaces: workspaces,
            viewModel: viewModel,
            selectedWorkspaceId: Binding(
                get: { viewModel.selectedWorkspaceId },
                set: { if let id = $0 { viewModel.selectWorkspace(id: id) } }
            ),
            scrollOffset: $scrollOffset,
            onAddNewTriggered: {
                let id = viewModel.model.createWorkspace(name: "Untitled", colorId: .randomColor())
                viewModel.selectedWorkspaceId = id
            }
        )
        .background(interpolatedBackground(workspaces: workspaces).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingOverview = true
                } label: {
                    Image(systemName: "square.stack")
                }
                .disabled(viewModel.isSelecting)
            }
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isSelecting {
                    Button("Done") {
                        viewModel.clearSelection()
                    }
                } else {
                    Menu {
                        Button {
                            showingAddItem = true
                        } label: {
                            Label("Add Item", systemImage: "plus.square")
                        }
                        Button {
                            importClipboardContent()
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                        Divider()
                        Button {
                            viewModel.isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        showingAddItem = true
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isSelecting && !viewModel.selectedNodeIds.isEmpty {
                BulkActionBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isSelecting && !viewModel.selectedNodeIds.isEmpty)
        .sheet(isPresented: $showingAddItem) {
            AddItemView()
                .environmentObject(viewModel)
        }
        .alert("Nothing to paste", isPresented: $showingEmptyClipboard) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy a URL, task, or text to your clipboard first.")
        }
    }

    // MARK: - Paste from Clipboard

    private func importClipboardContent() {
        guard let pasted = UIPasteboard.general.string else {
            showingEmptyClipboard = true
            return
        }
        let items = ClipboardImportParser.parse(pasted)
        if items.isEmpty {
            showingEmptyClipboard = true
            return
        }
        for item in items {
            switch item {
            case .task(let title, let isCompleted):
                let id = viewModel.model.addTask(title: title, parentId: nil)
                if isCompleted { viewModel.model.toggleTaskCompletion(id: id) }
            case .link(let url, let defaultTitle):
                let id = viewModel.model.addLink(urlString: url.absoluteString, title: defaultTitle, parentId: nil)
                fetchTitleForNewLink(id: id, url: url)
            case .snippet(let title, let content):
                viewModel.model.addSnippet(title: title, content: content, language: nil, parentId: nil)
            }
        }
    }

    private func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { title in
            guard let title else { return }
            _ = viewModel.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }

    // MARK: - Background Color Interpolation

    private func interpolatedBackground(workspaces: [Workspace]) -> Color {
        guard !workspaces.isEmpty else { return .clear }

        let rawPage = scrollOffset
        let fromIndex = max(0, min(workspaces.count - 1, Int(floor(rawPage))))
        let toIndex = max(0, min(workspaces.count, Int(floor(rawPage)) + 1))

        if toIndex < workspaces.count {
            let fraction = rawPage - floor(rawPage)
            let fromColor = workspaces[fromIndex].colorId.adaptiveBackgroundColor
            let toColor = workspaces[toIndex].colorId.adaptiveBackgroundColor
            if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
                return Color(uiColor: blended)
            }
            return Color(uiColor: fromColor)
        }

        if let last = workspaces.last {
            return Color(uiColor: last.colorId.adaptiveBackgroundColor)
        }
        return .clear
    }
}
