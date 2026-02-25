import SwiftUI
import StowShared

struct FaviconView: View {
    let link: StowShared.Link
    @EnvironmentObject var viewModel: AppViewModel
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .task {
            guard let url = URL(string: link.url) else { return }
            await withCheckedContinuation { continuation in
                FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { img, path in
                    self.image = img
                    if let path {
                        viewModel.model.updateLinkFaviconPath(id: link.id, path: path)
                    }
                    continuation.resume()
                }
            }
        }
    }
}
