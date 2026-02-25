import SwiftUI
import StowShared

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(workspace.colorId.color))
                .frame(width: 12, height: 12)
            Text(workspace.name)
                .lineLimit(1)
        }
    }
}
