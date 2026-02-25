import SwiftUI
import StowShared

struct WorkspacePageView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAddSheet = false
    @State private var scrollOffset: CGFloat = 0

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
        .navigationTitle(viewModel.currentWorkspace.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkspacePicker(scrollOffset: scrollOffset)
            }
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

    // MARK: - Background Color Interpolation

    private func interpolatedBackground(workspaces: [Workspace]) -> Color {
        guard !workspaces.isEmpty else { return .clear }

        let rawPage = scrollOffset
        let fromIndex = max(0, min(workspaces.count - 1, Int(floor(rawPage))))
        let toIndex = max(0, min(workspaces.count, Int(floor(rawPage)) + 1))

        if toIndex < workspaces.count {
            let fraction = rawPage - floor(rawPage)
            let fromColor = workspaces[fromIndex].colorId.backgroundColor
            let toColor = workspaces[toIndex].colorId.backgroundColor
            if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
                return Color(uiColor: blended)
            }
            return Color(uiColor: fromColor)
        }

        if let last = workspaces.last {
            return Color(uiColor: last.colorId.backgroundColor)
        }
        return .clear
    }
}
