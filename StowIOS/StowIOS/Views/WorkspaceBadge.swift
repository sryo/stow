import SwiftUI
import UIKit
import StowShared

/// A workspace's identity on its own color, as the Mac's workspace tile draws it: a 2×2
/// favicon mosaic, a letter, or a symbol. Metrics scale from the Mac's 36pt tile.
struct WorkspaceBadge: View {
    let colorId: WorkspaceColorId
    let identity: WorkspaceTileIdentity?
    var size: CGFloat = 28

    /// Every workspace's identity, resolved together so letters stay distinct. A favicon
    /// counts when its file is in this iPhone's icon folder: paths synced from the Mac
    /// point at the Mac's disk.
    static func identities(for workspaces: [Workspace], iconsDirectory: URL) -> [UUID: WorkspaceTileIdentity] {
        WorkspaceTileIdentity.resolve(workspaces) { FaviconStorage.fileName(for: $0, in: iconsDirectory) != nil }
    }

    private var scale: CGFloat { size / 36 }
    private var ink: Color { Color(StowTheme.colors(for: colorId, tint: .full).light.inkPrimary.platformColor) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 11 / 36, style: .continuous)
        shape
            .fill(Color(colorId.color))
            .overlay { content }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(WorkspaceDotView.edge).opacity(0.5), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch identity ?? .letter("?") {
        case .mosaic(let links):
            let inset = 4 * scale, gap = 2 * scale
            let cell = (size - inset * 2 - gap) / 2
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { column in
                            mosaicCell(index: row * 2 + column, links: links, side: cell)
                        }
                    }
                }
            }
        case .letter(let letters):
            let point = size * 0.48
            Text(letters)
                .font(.system(size: letters.count > 1 ? point * 0.82 : point, weight: .heavy))
                .kerning(-0.4 * scale)
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(ink)
        }
    }

    @ViewBuilder
    private func mosaicCell(index: Int, links: [StowShared.Link], side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
        if index < links.count,
           let image = FaviconImage.load(FaviconStorage.fileName(for: links[index], in: AppGroup.iconsDirectory)) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(shape)
        } else {
            shape.fill(Color.black.opacity(0.12)).frame(width: side, height: side)
        }
    }
}
