import AppKit

final class ListFlowLayout: NSCollectionViewFlowLayout {
    private var metrics: ListMetrics

    /// Mosaic tiles: minimum width, height and spacing.
    static let tileMinWidth: CGFloat = 132
    static let tileHeight: CGFloat = 78
    static let tileGap: CGFloat = 8

    func update(metrics: ListMetrics) {
        self.metrics = metrics
        let mosaic = metrics.mode == .mosaic
        minimumLineSpacing = mosaic ? Self.tileGap : metrics.verticalGap
        minimumInteritemSpacing = mosaic ? Self.tileGap : 0
        sectionInset = mosaic
            ? NSEdgeInsets(top: Self.tileGap, left: Self.tileGap, bottom: Self.tileGap, right: Self.tileGap)
            : NSEdgeInsets(top: metrics.verticalGap, left: 0, bottom: metrics.verticalGap, right: 0)
        invalidateLayout()
    }

    init(metrics: ListMetrics) {
        self.metrics = metrics
        super.init()
        scrollDirection = .vertical
        minimumLineSpacing = metrics.verticalGap
        minimumInteritemSpacing = 0
        sectionInset = NSEdgeInsets(top: metrics.verticalGap, left: 0, bottom: metrics.verticalGap, right: 0)
    }

    required init?(coder: NSCoder) {
        self.metrics = ListMetrics()
        super.init(coder: coder)
        scrollDirection = .vertical
        minimumLineSpacing = metrics.verticalGap
        minimumInteritemSpacing = 0
        sectionInset = NSEdgeInsets(top: metrics.verticalGap, left: 0, bottom: metrics.verticalGap, right: 0)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        updateItemSize(for: collectionView.bounds.size)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        updateItemSize(for: newBounds.size)
        return true
    }

    private func updateItemSize(for size: NSSize) {
        let scrollInsets = collectionView?.enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
        let availableWidth = size.width
            - sectionInset.left - sectionInset.right
            - scrollInsets.left - scrollInsets.right
        if availableWidth <= 1 {
            return
        }
        let width = max(1, availableWidth - 1)
        if metrics.mode == .mosaic {
            let columns = max(1, floor((width + Self.tileGap) / (Self.tileMinWidth + Self.tileGap)))
            let tileWidth = floor((width - (columns - 1) * Self.tileGap) / columns)
            itemSize = NSSize(width: tileWidth, height: Self.tileHeight)
        } else {
            itemSize = NSSize(width: width, height: metrics.rowHeight)
        }
    }
}
