import SwiftUI
import StowShared

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var showingOverview = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: NavigationSplitView
                NavigationSplitView {
                    WorkspaceSidebarView()
                } detail: {
                    NodeListView(workspaceId: viewModel.currentWorkspace.id)
                        .searchable(text: $viewModel.searchQuery, prompt: "Search items")
                        .background(Color(uiColor: viewModel.currentWorkspace.colorId.adaptiveBackgroundColor))
                }
                } else {
                // iPhone: Full-screen workspace pager (no tab bar)
                NavigationStack {
                    WorkspacePageView(showingOverview: $showingOverview)
                }
                .sheet(isPresented: $showingOverview) {
                    WorkspaceOverviewSheet()
                        .environmentObject(viewModel)
                }
                .alert("New Workspace", isPresented: $viewModel.showingNewWorkspaceAlert) {
                    TextField("Workspace Name", text: $viewModel.newWorkspaceName)
                    Button("Cancel", role: .cancel) {
                        viewModel.newWorkspaceName = ""
                    }
                    Button("Create") {
                        let name = viewModel.newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.newWorkspaceName = ""
                        if !name.isEmpty {
                            let id = viewModel.model.createWorkspace(name: name, colorId: .randomColor())
                            viewModel.selectedWorkspaceId = id
                        }
                    }
                } message: {
                    Text("Enter a name for the new workspace")
                }
            }
        }
        .alert("Couldn't Save Data", isPresented: Binding(
            get: { viewModel.saveErrorMessage != nil },
            set: { if !$0 { viewModel.saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.saveErrorMessage ?? "")
        }
    }
}
