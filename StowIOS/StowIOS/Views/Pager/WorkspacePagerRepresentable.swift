import SwiftUI
import StowShared

struct WorkspacePagerRepresentable: UIViewControllerRepresentable {
    let workspaces: [Workspace]
    let viewModel: AppViewModel
    @Binding var selectedWorkspaceId: UUID?
    @Binding var scrollOffset: CGFloat
    let onNewWorkspaceRequested: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> WorkspacePagerViewController {
        let vc = WorkspacePagerViewController()
        let coordinator = context.coordinator
        coordinator.pagerVC = vc

        vc.onOffsetChanged = { normalizedOffset in
            coordinator.parent.scrollOffset = normalizedOffset
        }
        vc.onSearchTextChanged = { text in
            coordinator.parent.viewModel.searchQuery = text
        }
        vc.onPageSnapped = { pageIndex in
            guard pageIndex < coordinator.parent.workspaces.count else { return }
            coordinator.isUpdatingFromSnap = true
            let id = coordinator.parent.workspaces[pageIndex].id
            coordinator.parent.selectedWorkspaceId = id
            coordinator.parent.viewModel.searchQuery = ""
            vc.searchController?.isActive = false
            // Clear flag after SwiftUI processes the binding update
            DispatchQueue.main.async {
                coordinator.isUpdatingFromSnap = false
            }
        }
        vc.onNewWorkspaceRequested = { [weak coordinator] in
            coordinator?.parent.onNewWorkspaceRequested()
        }

        let addNewView = AnyView(AddNewPageView())
        vc.updatePages(workspaces: workspaces, addNewView: addNewView, viewModel: viewModel)

        // Scroll to the initially selected workspace
        if let selectedId = selectedWorkspaceId,
           let index = workspaces.firstIndex(where: { $0.id == selectedId }) {
            vc.scrollToPage(index, animated: false)
        }

        coordinator.lastWorkspaceIds = workspaces.map(\.id)
        return vc
    }

    func updateUIViewController(_ vc: WorkspacePagerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let currentIds = workspaces.map(\.id)
        let idsChanged = currentIds != coordinator.lastWorkspaceIds

        if idsChanged {
            // Workspace list changed — rebuild pages
            let addNewView = AnyView(AddNewPageView())
            vc.updatePages(workspaces: workspaces, addNewView: addNewView, viewModel: viewModel)
            coordinator.lastWorkspaceIds = currentIds

            // Scroll to selected workspace after rebuild — no async to avoid flash
            if let selectedId = selectedWorkspaceId,
               let index = workspaces.firstIndex(where: { $0.id == selectedId }) {
                vc.scrollToPage(index, animated: false)
            }
            return
        }

        // Handle external selection changes (e.g. from WorkspacePicker)
        if coordinator.isUpdatingFromSnap { return }

        if let selectedId = selectedWorkspaceId,
           let targetIndex = workspaces.firstIndex(where: { $0.id == selectedId }),
           targetIndex != vc.currentPageIndex {
            vc.scrollToPage(targetIndex, animated: false)
        }
    }

    // MARK: - Coordinator

    final class Coordinator {
        var parent: WorkspacePagerRepresentable
        var isUpdatingFromSnap = false
        var lastWorkspaceIds: [UUID] = []
        weak var pagerVC: WorkspacePagerViewController?

        init(parent: WorkspacePagerRepresentable) {
            self.parent = parent
        }
    }
}
