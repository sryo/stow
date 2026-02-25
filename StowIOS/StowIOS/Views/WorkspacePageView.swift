import SwiftUI
import StowShared

struct WorkspacePageView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var showingAddSheet = false
    @State private var visiblePageId: UUID?
    @State private var backgroundColor: Color = .clear
    @State private var isUpdatingFromExternal = false
    @State private var scrollOffset: CGFloat = 0

    // Fixed sentinel UUID for the virtual "add new workspace" page
    private let addNewPageId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        let _ = viewModel.refreshTrigger
        let workspaces = viewModel.workspaces

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(workspaces) { workspace in
                    NodeListView(workspace: workspace)
                        .containerRelativeFrame(.horizontal)
                        .id(workspace.id)
                }

                // Virtual "Add New" page at the end
                addNewPageContent
                    .containerRelativeFrame(.horizontal)
                    .id(addNewPageId)
            }
            .scrollTargetLayout()
            .background {
                ScrollViewOffsetReader(offset: $scrollOffset, workspaceCount: workspaces.count)
            }
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visiblePageId)
        .background(interpolatedBackground(workspaces: workspaces).ignoresSafeArea())
        .onAppear {
            if visiblePageId == nil {
                visiblePageId = viewModel.selectedWorkspaceId ?? workspaces.first?.id
            }
            updateBackgroundColor(workspaces: workspaces)
        }
        .onChange(of: visiblePageId) { _, newId in
            guard let newId else { return }

            if newId == addNewPageId {
                // Scroll back to last workspace first, then show the alert
                scrollBackToLastWorkspace()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    viewModel.showingNewWorkspaceAlert = true
                }
                return
            }

            // Sync selection to model (skip if driven by external change)
            guard !isUpdatingFromExternal else { return }
            viewModel.selectWorkspace(id: newId)
        }
        .onChange(of: viewModel.selectedWorkspaceId) { _, newId in
            guard let newId, newId != visiblePageId else { return }
            isUpdatingFromExternal = true
            withAnimation(.easeInOut(duration: ThemeConstants.Paging.snapDuration)) {
                visiblePageId = newId
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ThemeConstants.Paging.snapDuration) {
                isUpdatingFromExternal = false
            }
        }
        .onChange(of: viewModel.workspaces) { _, newWorkspaces in
            if let id = visiblePageId, id != addNewPageId,
               !newWorkspaces.contains(where: { $0.id == id }) {
                visiblePageId = viewModel.selectedWorkspaceId ?? newWorkspaces.first?.id
            }
            updateBackgroundColor(workspaces: newWorkspaces)
        }
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

    // MARK: - Add New Page Content

    private var addNewPageContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("New Workspace")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Background Color Interpolation

    private func interpolatedBackground(workspaces: [Workspace]) -> Color {
        let screenWidth = UIScreen.main.bounds.width
        guard screenWidth > 0, !workspaces.isEmpty else { return backgroundColor }

        let rawPage = scrollOffset / screenWidth
        let fromIndex = max(0, min(workspaces.count - 1, Int(floor(rawPage))))
        let toIndex = max(0, min(workspaces.count, Int(floor(rawPage)) + 1))

        // If both indices point to real workspaces, interpolate between them
        if toIndex < workspaces.count {
            let fraction = rawPage - floor(rawPage)
            let fromColor = workspaces[fromIndex].colorId.backgroundColor
            let toColor = workspaces[toIndex].colorId.backgroundColor
            if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
                return Color(uiColor: blended)
            }
            return Color(uiColor: fromColor)
        }

        // Past last workspace (add-new page) — use last workspace color
        if let last = workspaces.last {
            return Color(uiColor: last.colorId.backgroundColor)
        }
        return backgroundColor
    }

    // MARK: - Helpers

    private func updateBackgroundColor(workspaces: [Workspace]) {
        if let id = visiblePageId, let workspace = workspaces.first(where: { $0.id == id }) {
            backgroundColor = Color(uiColor: workspace.colorId.backgroundColor)
        } else if let first = workspaces.first {
            backgroundColor = Color(uiColor: first.colorId.backgroundColor)
        }
    }

    private func scrollBackToLastWorkspace() {
        if let lastWorkspace = viewModel.workspaces.last {
            withAnimation {
                visiblePageId = lastWorkspace.id
            }
        }
    }
}

// MARK: - Scroll View Offset Reader

/// Introspects the underlying UIScrollView of a SwiftUI ScrollView to provide
/// continuous content offset updates on every frame via UIScrollViewDelegate.
/// Also drives continuous haptic feedback when scrolling into the add-new zone.
private struct ScrollViewOffsetReader: UIViewRepresentable {
    @Binding var offset: CGFloat
    var workspaceCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            if let scrollView = findScrollView(in: view) {
                context.coordinator.attach(to: scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.workspaceCount = workspaceCount
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let parent = current?.superview {
            if let scrollView = parent as? UIScrollView {
                return scrollView
            }
            current = parent
        }
        return nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ScrollViewOffsetReader
        var workspaceCount: Int
        private weak var scrollView: UIScrollView?
        private weak var originalDelegate: UIScrollViewDelegate?
        private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
        private var lastHapticTime: TimeInterval = 0

        init(parent: ScrollViewOffsetReader) {
            self.parent = parent
            self.workspaceCount = parent.workspaceCount
        }

        func attach(to scrollView: UIScrollView) {
            self.scrollView = scrollView
            self.originalDelegate = scrollView.delegate
            scrollView.delegate = self
            hapticGenerator.prepare()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset.x
            parent.offset = offset
            originalDelegate?.scrollViewDidScroll?(scrollView)

            // Continuous haptics when dragging past the last workspace into the add-new zone
            let screenWidth = scrollView.bounds.width
            guard screenWidth > 0, workspaceCount > 0 else { return }
            let lastWorkspaceOffset = CGFloat(workspaceCount - 1) * screenWidth
            let inAddNewZone = offset > lastWorkspaceOffset + 1
            if inAddNewZone {
                // Re-prepare on zone entry so the generator stays active
                if lastHapticTime == 0 {
                    hapticGenerator.prepare()
                }
                let now = CACurrentMediaTime()
                if now - lastHapticTime >= 0.05 {
                    hapticGenerator.impactOccurred(intensity: 0.4)
                    lastHapticTime = now
                }
            } else {
                lastHapticTime = 0
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            hapticGenerator.prepare()
            originalDelegate?.scrollViewWillBeginDragging?(scrollView)
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            originalDelegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidEndDecelerating?(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidEndScrollingAnimation?(scrollView)
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            originalDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidScrollToTop?(scrollView)
        }

        func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
            originalDelegate?.scrollViewDidChangeAdjustedContentInset?(scrollView)
        }
    }
}
