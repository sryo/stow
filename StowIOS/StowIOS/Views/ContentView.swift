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
                        .background(Color(uiColor: viewModel.background(for: viewModel.currentWorkspace.colorId)))
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
            }
        }
        .undoToast(viewModel.undoToasts)
        .sheet(item: $viewModel.workspaceEditor) { editor in
            WorkspaceEditorSheet(editor: editor)
                .environmentObject(viewModel)
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
