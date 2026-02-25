import AppKit

/// A dynamic grid view that displays pinned link tiles.
@MainActor
final class PinnedTabsView: NSView {
    private var tileViews: [PinnedTabTileView] = []
    private let columns = ThemeConstants.Sizing.pinnedTileColumns
    private let tileHeight = ThemeConstants.Sizing.pinnedTileHeight
    private let spacing: CGFloat = ThemeConstants.Spacing.tiny

    var onTileClicked: ((UUID) -> Void)?
    var onTileRightClicked: ((UUID, NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(links: [Link]) {
        // Remove old tiles
        for tile in tileViews {
            tile.removeFromSuperview()
        }
        tileViews.removeAll()

        guard !links.isEmpty else {
            isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        isHidden = false

        // Create tiles
        for link in links {
            let tile = PinnedTabTileView(link: link)
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.onClick = { [weak self] id in self?.onTileClicked?(id) }
            tile.onRightClick = { [weak self] id, point in self?.onTileRightClicked?(id, point) }
            addSubview(tile)
            tileViews.append(tile)
        }

        layoutTiles()
        invalidateIntrinsicContentSize()
    }

    func updateFavicon(linkId: UUID, link: Link) {
        if let tile = tileViews.first(where: { $0.linkId == linkId }) {
            tile.updateFavicon(link: link)
        }
    }

    override var intrinsicContentSize: NSSize {
        guard !tileViews.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        let rows = ceil(Double(tileViews.count) / Double(columns))
        let height = CGFloat(rows) * tileHeight + CGFloat(max(0, Int(rows) - 1)) * spacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        layoutTiles()
    }

    private func layoutTiles() {
        guard !tileViews.isEmpty else { return }

        let availableWidth = bounds.width
        let tileWidth = (availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)

        for (index, tile) in tileViews.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = CGFloat(col) * (tileWidth + spacing)
            let y = CGFloat(row) * (tileHeight + spacing)
            tile.frame = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
        }
    }
}
