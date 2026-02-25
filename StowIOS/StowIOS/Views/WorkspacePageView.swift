import SwiftUI
import StowShared

struct WorkspacePageView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAddSheet = false

    var body: some View {
        let _ = viewModel.refreshTrigger

        let workspaces = viewModel.workspaces
        let selectedId = viewModel.selectedWorkspaceId

        TabView(selection: Binding(
            get: { selectedId ?? workspaces.first?.id },
            set: { newId in
                if let id = newId {
                    viewModel.selectWorkspace(id: id)
                }
            }
        )) {
            ForEach(workspaces) { workspace in
                NodeListView(workspace: workspace)
                    .tag(workspace.id as UUID?)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(workspaceBackground)
        .navigationTitle(viewModel.currentWorkspace.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddItemView()
                .environmentObject(viewModel)
        }
    }

    private var workspaceBackground: Color {
        Color(uiColor: viewModel.currentWorkspace.colorId.backgroundColor)
    }
}
