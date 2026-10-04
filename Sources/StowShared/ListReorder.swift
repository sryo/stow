import Foundation

/// Index math for reordering a list that shows only some of its parent's items
/// (the rail hides tasks and snippets; lists hide archived items).
public enum ListReorder {
    /// The `AppModel.moveNode` index for dropping `moving` into gap `slot` (0...count) of the
    /// visible list. The index is found in the parent's full item list, so hidden items keep
    /// their places. Nil when the drop leaves the order unchanged.
    public static func modelIndex(forSlot slot: Int, moving: UUID, visibleIds: [UUID], allIds: [UUID]) -> Int? {
        guard let from = visibleIds.firstIndex(of: moving), slot != from, slot != from + 1 else { return nil }
        if slot < visibleIds.count {
            return allIds.firstIndex(of: visibleIds[slot])
        }
        guard let last = visibleIds.last, let lastIndex = allIds.firstIndex(of: last) else { return nil }
        return lastIndex + 1
    }
}
