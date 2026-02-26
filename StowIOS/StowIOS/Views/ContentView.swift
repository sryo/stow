import SwiftUI
import StowShared

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.horizontalSizeClass) var sizeClass
    @State private var selectedTab = 0
    @State private var showingOverview = false

    var body: some View {
        let _ = viewModel.refreshTrigger // observe changes

        if sizeClass == .regular {
            // iPad: NavigationSplitView
            NavigationSplitView {
                WorkspaceSidebarView()
            } detail: {
                NodeListView(workspaceId: viewModel.currentWorkspace.id)
                    .background(Color(uiColor: viewModel.currentWorkspace.colorId.backgroundColor))
            }
        } else {
            // iPhone: TabView with Bookmarks + Workspaces + Settings
            TabView(selection: $selectedTab) {
                NavigationStack {
                    WorkspacePageView()
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
                .tabItem {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                .tag(0)

                EmptyView()
                    .tabItem {
                        Label("Workspaces", systemImage: "square.stack")
                    }
                    .tag(1)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(2)
            }
            .onChange(of: selectedTab) { _, newValue in
                if newValue == 1 {
                    showingOverview = true
                    selectedTab = 0
                }
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
}
