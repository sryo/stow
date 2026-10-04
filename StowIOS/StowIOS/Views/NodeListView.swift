import SwiftUI
import StowShared

struct NodeListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.undoManager) private var undoManager
    let workspaceId: UUID
    var showHeader: Bool = false

    private var searchQuery: String { viewModel.searchQuery }

    private var workspace: Workspace? {
        viewModel.model.workspaces.first { $0.id == workspaceId }
    }

    private var displayedItems: [Node] {
        guard let workspace else { return [] }
        let activeItems = workspace.items.unarchived()
        if searchQuery.isEmpty {
            return activeItems
        }
        return NodeFiltering.filter(nodes: activeItems, query: searchQuery)
    }

    /// Everything archived, wherever it was archived; an archived folder shows its
    /// children inside its own disclosure.
    private var archivedItems: [Node] {
        guard let workspace else { return [] }
        return workspace.items.archivedLeaves()
    }

    var body: some View {
        if let workspace {
            let colors = StowTheme.colors(for: workspace.colorId, tint: viewModel.effectiveTint)
            List {
                if showHeader {
                    Text(workspace.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if let copy = emptyStateCopy(for: workspace) {
                    VStack(spacing: 8) {
                        NotchIllustration(scene: copy.scene.notchScene)
                            .padding(.bottom, 6)
                        Text(copy.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(colors.ink)
                            .multilineTextAlignment(.center)
                        Text(copy.message)
                            .font(.subheadline)
                            .foregroundStyle(colors.inkSoft)
                            .multilineTextAlignment(.center)
                        if copy.action == .paste || copy.action == .addBookmarksMenu {
                            // The system paste button reads the clipboard without the "Allow Paste" prompt.
                            PasteButton(payloadType: String.self) { texts in
                                Task { @MainActor in importPasted(texts.joined(separator: "\n")) }
                            }
                            .buttonBorderShape(.roundedRectangle(radius: StowTheme.List.rowRadius))
                            .tint(colors.accentColor)
                            .labelStyle(.titleAndIcon)
                            .padding(.top, 8)
                        } else if let label = copy.actionLabel, let action = copy.action {
                            Button {
                                perform(action, workspace: workspace)
                            } label: {
                                Text(label)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(colors.ink)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .overlay(RoundedRectangle(cornerRadius: StowTheme.List.rowRadius).stroke(colors.inkSoft, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(copy.actionAccessibilityLabel ?? label)
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .padding(.horizontal, 24)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedItems, id: \.id) { node in
                        selectableRow(for: node)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    viewModel.archive([node.id], undoManager: undoManager)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(StowTheme.Colors.actionArchiveColor)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                leadingSwipeAction(for: node)
                            }
                            .listRowBackground(Color.clear)
                    }
                    .onMove { indices, destination in
                        guard searchQuery.isEmpty else { return }
                        RowMove.apply(indices, to: destination, shown: displayedItems, all: workspace.items,
                                      parentId: nil, model: viewModel.model)
                    }
                }

                // Archive section (hidden during search)
                if !archivedItems.isEmpty && searchQuery.isEmpty {
                    Section(isExpanded: Binding(
                        get: { workspace.isArchiveExpanded },
                        set: { viewModel.model.setArchiveExpanded(workspaceId: workspaceId, isExpanded: $0) }
                    )) {
                        ForEach(archivedItems, id: \.id) { node in
                            NodeRowView(node: node, parentId: nil, isArchived: true)
                                // Deleting for good takes a deliberate tap, not a full swipe.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        viewModel.deletePermanently(node.id, undoManager: undoManager)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.model.unarchiveNode(id: node.id)
                                    } label: {
                                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(StowTheme.Colors.actionPrimaryColor)
                                }
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Archive · \(archivedItems.count)")
                            .foregroundStyle(colors.inkSoft)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.stowColors, colors)
            .tint(colors.accentColor)
        } else {
            ContentUnavailableView("Workspace Not Found", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: - Empty State

    private func emptyStateCopy(for workspace: Workspace) -> EmptyStateCopy? {
        let active = workspace.items.unarchived()
        let archivedMatches = searchQuery.isEmpty ? [] : NodeFiltering.filter(nodes: archivedItems, query: searchQuery, includeArchived: true)
        let kind = EmptyStateKind.resolve(
            activeCount: active.count,
            archivedCount: archivedItems.count,
            query: searchQuery,
            matchedCount: displayedItems.count,
            archivedMatchedCount: archivedMatches.count,
            isArchiveExpanded: workspace.isArchiveExpanded,
            isFirstLaunch: false,
            hasArcData: false
        )
        return EmptyStateCopy.make(kind, workspaceName: workspace.name, isTouch: true)
    }

    private func perform(_ action: EmptyStateAction, workspace: Workspace) {
        switch action {
        case .clearSearch:
            viewModel.searchQuery = ""
        case .showArchive, .showArchivedMatches:
            viewModel.searchQuery = ""
            viewModel.model.setArchiveExpanded(workspaceId: workspace.id, isExpanded: true)
        case .paste, .addBookmarksMenu:
            break
        }
    }

    private func importPasted(_ text: String) {
        for item in ClipboardImportParser.parse(text) {
            switch item {
            case .task(let title, let done):
                let id = viewModel.model.addTask(title: title, parentId: nil)
                if done { viewModel.model.toggleTaskCompletion(id: id) }
            case .link(let url, let title):
                viewModel.model.addLink(urlString: url.absoluteString, title: title, parentId: nil)
            case .snippet(let title, let content):
                viewModel.model.addSnippet(title: title, content: content, language: nil, parentId: nil)
            }
        }
    }

    // MARK: - Selectable Row

    @ViewBuilder
    private func selectableRow(for node: Node) -> some View {
        if viewModel.isSelecting {
            HStack(spacing: 12) {
                Image(systemName: viewModel.selectedNodeIds.contains(node.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(viewModel.selectedNodeIds.contains(node.id)
                        ? StowTheme.colors(for: workspace?.colorId ?? .defaultColor(), tint: viewModel.effectiveTint).accentColor
                        : StowTheme.colors(for: workspace?.colorId ?? .defaultColor(), tint: viewModel.effectiveTint).inkSoft)
                NodeRowView(node: node, parentId: nil)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if viewModel.selectedNodeIds.contains(node.id) {
                    viewModel.selectedNodeIds.remove(node.id)
                } else {
                    viewModel.selectedNodeIds.insert(node.id)
                }
            }
        } else {
            NodeRowView(node: node, parentId: nil)
        }
    }

    // MARK: - Leading Swipe Actions

    @ViewBuilder
    private func leadingSwipeAction(for node: Node) -> some View {
        switch node {
        case .link(let link):
            Button {
                let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
                if let url = URL(string: urlString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open", systemImage: "safari")
            }
            .tint(StowTheme.Colors.actionPrimaryColor)

        case .task(let task):
            Button {
                viewModel.model.toggleTaskCompletion(id: task.id)
            } label: {
                Label(
                    task.isCompleted ? "Uncomplete" : "Complete",
                    systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(StowTheme.Colors.actionPrimaryColor)

        default:
            EmptyView()
        }
    }
}

/// Applies a SwiftUI `.onMove` to the model. `destination` is a gap among the rows the
/// list shows, while `AppModel.moveNode` counts every item under the parent.
enum RowMove {
    static func apply(_ indices: IndexSet, to destination: Int, shown: [Node], all: [Node], parentId: UUID?, model: AppModel) {
        guard let first = indices.first, shown.indices.contains(first) else { return }
        let id = shown[first].id
        guard let index = ListReorder.modelIndex(forSlot: destination, moving: id,
                                                 visibleIds: shown.map(\.id), allIds: all.map(\.id)) else { return }
        model.moveNode(id: id, toParentId: parentId, index: index)
    }
}
