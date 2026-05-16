import SwiftUI
import StowShared

struct NodeListView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let workspaceId: UUID
    var showHeader: Bool = false

    private var searchQuery: String { viewModel.searchQuery }

    private var workspace: Workspace? {
        viewModel.model.workspaces.first { $0.id == workspaceId }
    }

    private var displayedItems: [Node] {
        guard let workspace else { return [] }
        let activeItems = workspace.items.filter { !$0.isArchived }
        if searchQuery.isEmpty {
            return activeItems
        }
        return NodeFiltering.filter(nodes: activeItems, query: searchQuery)
    }

    private var archivedItems: [Node] {
        guard let workspace else { return [] }
        return workspace.items.filter { $0.isArchived }
    }

    private var flattenedArchivedItems: [FlatNode] {
        Self.flattenNodes(archivedItems, depth: 0)
    }

    private static func flattenNodes(_ nodes: [Node], depth: Int) -> [FlatNode] {
        var result: [FlatNode] = []
        for node in nodes {
            result.append(FlatNode(node: node, depth: depth))
            if case .folder(let folder) = node {
                result.append(contentsOf: flattenNodes(folder.children, depth: depth + 1))
            }
        }
        return result
    }

    var body: some View {
        let _ = viewModel.refreshTrigger

        if let workspace {
            List {
                if showHeader {
                    Text(workspace.name)
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if displayedItems.isEmpty && archivedItems.isEmpty {
                    ContentUnavailableView(
                        searchQuery.isEmpty ? "No Items" : "No Results",
                        systemImage: searchQuery.isEmpty ? "bookmark" : "magnifyingglass",
                        description: Text(
                            searchQuery.isEmpty
                                ? "Add links, folders, tasks, or snippets to get started."
                                : "No items match your search."
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if displayedItems.isEmpty && !searchQuery.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No items match your search.")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(displayedItems, id: \.id) { node in
                        NodeRowView(node: node, parentId: nil)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    viewModel.model.deleteNode(id: node.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                leadingSwipeAction(for: node)
                            }
                            .listRowBackground(Color.clear)
                    }
                    .onMove { indices, destination in
                        guard searchQuery.isEmpty else { return }
                        guard let first = indices.first else { return }
                        let nodeId = displayedItems[first].id
                        viewModel.model.moveNode(id: nodeId, toParentId: nil, index: destination)
                    }
                }

                // Archive section (hidden during search)
                if !archivedItems.isEmpty && searchQuery.isEmpty {
                    Section(isExpanded: Binding(
                        get: { workspace.isArchiveExpanded },
                        set: { viewModel.model.setArchiveExpanded(workspaceId: workspaceId, isExpanded: $0) }
                    )) {
                        ForEach(flattenedArchivedItems, id: \.node.id) { entry in
                            NodeRowView(node: entry.node, parentId: nil, isArchived: true)
                                .padding(.leading, CGFloat(entry.depth) * 20)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.model.permanentlyDeleteNode(id: entry.node.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.model.unarchiveNode(id: entry.node.id)
                                    } label: {
                                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.blue)
                                }
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Archive (\(archivedItems.count))")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("Workspace Not Found", systemImage: "exclamationmark.triangle")
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
            .tint(.blue)

        case .task(let task):
            Button {
                viewModel.model.toggleTaskCompletion(id: task.id)
            } label: {
                Label(
                    task.isCompleted ? "Uncomplete" : "Complete",
                    systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(.green)

        default:
            EmptyView()
        }
    }
}

private struct FlatNode {
    let node: Node
    let depth: Int
}
