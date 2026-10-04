import AppKit

/// Pure geometry and index math for dragging items on the Elastic rail.
enum RailDrag {
    /// Distance the pointer must travel before a press becomes a drag.
    static let startThreshold: CGFloat = 4
    /// Workspace dots are 12pt; a drop counts within this much of one.
    static let dotTolerance: CGFloat = 8

    /// The gap (0...count) a drag at `dragY` points to, split at each cell's midpoint.
    static func targetSlot(dragY: CGFloat, cellFrames: [NSRect]) -> Int {
        cellFrames.firstIndex { dragY < $0.midY } ?? cellFrames.count
    }

    /// The `AppModel.moveNode` index for dropping `moving` into rail gap `slot`. The rail
    /// only shows links and folders, so the index is found in the full item list, where
    /// tasks and snippets sit in between. Nil when the drop leaves the order unchanged.
    static func modelIndex(forSlot slot: Int, moving: UUID, railIds: [UUID], itemIds: [UUID]) -> Int? {
        guard let from = railIds.firstIndex(of: moving), slot != from, slot != from + 1 else { return nil }
        if slot < railIds.count {
            return itemIds.firstIndex(of: railIds[slot])
        }
        guard let last = railIds.last, let lastIndex = itemIds.firstIndex(of: last) else { return nil }
        return lastIndex + 1
    }

    /// The workspace whose dot is under `point`, or nil for the current one or empty space.
    static func workspaceDrop(at point: NSPoint, dots: [(UUID, NSRect)], current: UUID) -> UUID? {
        let hits = dots.filter { $0.1.insetBy(dx: -dotTolerance, dy: -dotTolerance).contains(point) }
        let nearest = hits.min { distance($0.1, point) < distance($1.1, point) }
        guard let id = nearest?.0, id != current else { return nil }
        return id
    }

    private static func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }
}
