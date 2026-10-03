import AppKit

/// Geometry for the node list at list, sidebar and mosaic widths, following the
/// Elastic mockup's `listL` and `mosL` layouts.
final class ElasticLayout: NSCollectionViewLayout {
    enum Shape: Equatable {
        /// A full-width row (list and sidebar, and the archive header everywhere).
        case row
        /// "TASKS · 2 open" and friends: a section label with spacing above it.
        case sectionHeader
        /// A folder's label over its tiles in the mosaic.
        case groupHeader
        case linkTile
        case taskTile
        case snippetTile
    }

    var mode: ElasticMode = .sidebar { didSet { if mode != oldValue { invalidateLayout() } } }
    var rowHeight: CGFloat = 28 { didSet { if rowHeight != oldValue { invalidateLayout() } } }
    var shapes: [Shape] = [] { didSet { invalidateLayout() } }

    static let listTop: CGFloat = 4
    static let listBottom: CGFloat = 8
    static let firstSectionGap: CGFloat = 10
    static let sectionGap: CGFloat = 6
    static let sidebarSectionHeight: CGFloat = 26

    /// The mosaic's side padding is 14pt from the panel edge; the list view starts 6pt in.
    static let mosaicInset: CGFloat = 8
    static let tileMinWidth: CGFloat = 118
    static let tileGap: CGFloat = 8
    static let linkTileHeight: CGFloat = 80
    static let taskTileHeight: CGFloat = 38
    static let snippetTileHeight: CGFloat = 80
    static let groupHeaderHeight: CGFloat = 24
    static let groupGap: CGFloat = 10

    private var frames: [NSRect] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = -1

    override func prepare() {
        super.prepare()
        let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 0
        preparedWidth = width
        frames = mode == .mosaic ? mosaicFrames(width: width) : listFrames(width: width)
    }

    private func listFrames(width: CGFloat) -> [NSRect] {
        var result: [NSRect] = []
        result.reserveCapacity(shapes.count)
        var y = Self.listTop
        var sawSection = false
        for shape in shapes {
            if shape == .sectionHeader {
                y += sawSection ? Self.sectionGap : Self.firstSectionGap
                sawSection = true
                let h = mode == .sidebar ? Self.sidebarSectionHeight : rowHeight
                result.append(NSRect(x: 0, y: y, width: width, height: h))
                y += h
            } else {
                result.append(NSRect(x: 0, y: y, width: width, height: rowHeight))
                y += rowHeight
            }
        }
        contentHeight = y + Self.listBottom
        return result
    }

    /// Number of mosaic columns for a list width, never fewer than two.
    static func columns(forWidth width: CGFloat) -> Int {
        let avail = max(60, width - mosaicInset * 2)
        return max(2, Int(floor((avail + tileGap) / (tileMinWidth + tileGap))))
    }

    private func mosaicFrames(width: CGFloat) -> [NSRect] {
        let pad = Self.mosaicInset, gap = Self.tileGap
        let avail = max(60, width - pad * 2)
        let cols = Self.columns(forWidth: width)
        let tileWidth = (avail - CGFloat(cols - 1) * gap) / CGFloat(cols)
        var result: [NSRect] = []
        result.reserveCapacity(shapes.count)
        var y = Self.listTop, col = 0, rowH: CGFloat = 0, first = true

        func newLine() {
            if col > 0 { y += rowH + gap; col = 0; rowH = 0 }
        }
        func place(span: Int, height: CGFloat) -> NSRect {
            let span = min(span, cols)
            if col + span > cols { newLine() }
            let r = NSRect(x: pad + CGFloat(col) * (tileWidth + gap), y: y,
                           width: CGFloat(span) * tileWidth + CGFloat(span - 1) * gap, height: height)
            col += span
            rowH = max(rowH, height)
            return r
        }
        func header(height: CGFloat) -> NSRect {
            newLine()
            if !first { y += Self.groupGap }
            first = false
            let r = NSRect(x: pad, y: y, width: avail, height: height)
            y += height + 4
            return r
        }

        // Tasks and snippets are wide: two columns once there are four, else the full row.
        let wideSpan = cols >= 4 ? 2 : cols
        for shape in shapes {
            switch shape {
            case .sectionHeader, .groupHeader:
                result.append(header(height: Self.groupHeaderHeight))
            case .row:
                result.append(header(height: rowHeight))
            case .linkTile:
                result.append(place(span: 1, height: Self.linkTileHeight))
            case .taskTile:
                result.append(place(span: wideSpan, height: Self.taskTileHeight))
            case .snippetTile:
                result.append(place(span: wideSpan, height: Self.snippetTileHeight))
            }
        }
        newLine()
        contentHeight = y + Self.groupGap
        return result
    }

    override var collectionViewContentSize: NSSize {
        let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width ?? 0
        let visibleHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 0
        return NSSize(width: width, height: max(contentHeight, visibleHeight))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        for (i, frame) in frames.enumerated() where frame.intersects(rect) {
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            a.frame = frame
            result.append(a)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < frames.count else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        a.frame = frames[indexPath.item]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }

    // MARK: - Drops

    /// Over the upper three quarters of an item the drop targets that item (the controller
    /// decides between "on" and "before"); below that, the gap after it.
    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard !frames.isEmpty else { return gapAttributes(before: 0) }
        if let i = frames.firstIndex(where: { $0.contains(point) }) {
            let f = frames[i]
            if point.y > f.maxY - f.height * 0.25 {
                return i + 1 < frames.count ? layoutAttributesForItem(at: IndexPath(item: i + 1, section: 0)) : gapAttributes(before: frames.count)
            }
            return layoutAttributesForItem(at: IndexPath(item: i, section: 0))
        }
        // Between items: the first one starting below the point.
        if let i = frames.firstIndex(where: { $0.minY > point.y || ($0.maxY > point.y && $0.minX > point.x) }) {
            return layoutAttributesForItem(at: IndexPath(item: i, section: 0))
        }
        return gapAttributes(before: frames.count)
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        gapAttributes(before: indexPath.item)
    }

    private func gapAttributes(before item: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: item, section: 0))
        let y = item < frames.count ? frames[item].minY : (frames.last?.maxY ?? 0)
        a.frame = NSRect(x: 0, y: y - 1, width: collectionView?.bounds.width ?? 0, height: 2)
        return a
    }
}
