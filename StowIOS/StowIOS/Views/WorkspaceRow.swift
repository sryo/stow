import SwiftUI
import StowShared

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceDotView(colorId: workspace.colorId)
            Text(workspace.name)
                .lineLimit(1)
        }
    }
}
