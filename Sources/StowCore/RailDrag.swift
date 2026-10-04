import AppKit

/// Pure geometry and index math for dragging items on the Elastic rail, and for dropping
/// them on workspaces (rail dots, workspace tabs).
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
    /// only shows links and folders, so tasks and snippets in between keep their places.
    static func modelIndex(forSlot slot: Int, moving: UUID, railIds: [UUID], itemIds: [UUID]) -> Int? {
        ListReorder.modelIndex(forSlot: slot, moving: moving, visibleIds: railIds, allIds: itemIds)
    }

    /// The `AppModel` index for text dropped into rail gap `slot`: before the rail item
    /// at that gap, after the last one at the end, or the top of an empty rail.
    static func textDropIndex(forSlot slot: Int, railIds: [UUID], itemIds: [UUID]) -> Int {
        if slot < railIds.count, let index = itemIds.firstIndex(of: railIds[slot]) { return index }
        if let last = railIds.last, let index = itemIds.firstIndex(of: last) { return index + 1 }
        return 0
    }

    /// The workspace whose dot is under `point`, or nil for the current one or empty space.
    static func workspaceDrop(at point: NSPoint, dots: [(UUID, NSRect)], current: UUID) -> UUID? {
        workspaceTarget(at: point, targets: dots, current: current, tolerance: dotTolerance)
    }

    /// The workspace whose shape (a rail dot, a workspace tab) is nearest `point` within
    /// `tolerance`, or nil for the current workspace or empty space.
    static func workspaceTarget(at point: NSPoint, targets: [(UUID, NSRect)], current: UUID?,
                                tolerance: CGFloat = 0) -> UUID? {
        let hits = targets.filter { $0.1.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        let nearest = hits.min { distance($0.1, point) < distance($1.1, point) }
        guard let id = nearest?.0, id != current else { return nil }
        return id
    }

    private static func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }
}
