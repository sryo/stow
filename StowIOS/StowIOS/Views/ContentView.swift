import SwiftUI
import StowShared

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.horizontalSizeClass) var sizeClass

    var body: some View {
        let _ = viewModel.refreshTrigger // observe changes

        if sizeClass == .regular {
            // iPad: NavigationSplitView
            NavigationSplitView {
                WorkspaceSidebarView()
            } detail: {
                NodeListView(workspace: viewModel.currentWorkspace)
                    .background(Color(uiColor: viewModel.currentWorkspace.colorId.backgroundColor))
            }
        } else {
            // iPhone: TabView with Bookmarks + Settings
            TabView {
                NavigationStack {
                    WorkspacePageView()
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .tabItem {
                    Label("Bookmarks", systemImage: "bookmark")
                }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
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
}
