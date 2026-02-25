import SwiftUI
import StowShared

struct WorkspacePicker: View {
    @EnvironmentObject var viewModel: AppViewModel
    var scrollOffset: CGFloat = 0

    var body: some View {
        let _ = viewModel.refreshTrigger
        let workspaces = viewModel.workspaces

        Menu {
            ForEach(workspaces) { workspace in
                Button(action: { viewModel.selectWorkspace(id: workspace.id) }) {
                    Label(workspace.name, systemImage: "circle.fill")
                }
            }

            Divider()

            Button(action: {
                let id = viewModel.model.createWorkspace(name: "Untitled", colorId: .randomColor())
                viewModel.selectedWorkspaceId = id
            }) {
                Label("New Workspace", systemImage: "plus")
            }
        } label: {
            slidingLabel(workspaces: workspaces)
        }
    }

    // MARK: - Sliding Label

    @ViewBuilder
    private func slidingLabel(workspaces: [Workspace]) -> some View {
        let clampedOffset = max(0, min(scrollOffset, CGFloat(workspaces.count - 1)))
        let currentIndex = Int(floor(clampedOffset))
        let fraction = clampedOffset - CGFloat(currentIndex)

        let currentWorkspace = workspaces.indices.contains(currentIndex) ? workspaces[currentIndex] : nil
        let nextWorkspace = workspaces.indices.contains(currentIndex + 1) ? workspaces[currentIndex + 1] : nil

        ZStack {
            if let current = currentWorkspace {
                titleRow(name: current.name, color: current.colorId.color)
                    .offset(x: -fraction * 120)
                    .opacity(Double(1 - fraction))
            }
            if let next = nextWorkspace, fraction > 0.01 {
                titleRow(name: next.name, color: next.colorId.color)
                    .offset(x: (1 - fraction) * 120)
                    .opacity(Double(fraction))
            }
        }
        .clipped()
    }

    private func titleRow(name: String, color: PlatformColor) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(color))
                .frame(width: 10, height: 10)
            Text(name)
                .font(.headline)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
