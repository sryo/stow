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
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                WorkspacePicker()
                            }
                        }
                }
                .tabItem {
                    Label("Bookmarks", systemImage: "bookmark")
                }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        }
    }
}
