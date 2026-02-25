import SwiftUI
import StowShared

struct PinnedLinksView: View {
    let pinnedLinks: [StowShared.Link]
    @EnvironmentObject var viewModel: AppViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        if !pinnedLinks.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(pinnedLinks) { link in
                    Button(action: {
                        if let url = URL(string: link.url) {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        VStack(spacing: 4) {
                            FaviconView(link: link)
                            Text(link.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.model.unpinLink(id: link.id)
                        } label: {
                            Label("Unpin", systemImage: "pin.slash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
