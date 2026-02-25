import SwiftUI

struct AddNewPageView: View {
    var body: some View {
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
}
