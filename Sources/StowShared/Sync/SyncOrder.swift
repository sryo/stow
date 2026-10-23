import Foundation

/// Sparse sort orders for synced siblings. A reorder keeps the orders of the longest
/// run of items still in order and gives new ones only to the rest, so a move uploads
/// the items that moved and two devices moving different items both keep their move.
public enum SyncOrder {
    /// Gap between neighbours on a fresh numbering; room for ~20 halvings before a renumber.
    public static let spacing = 1 << 20

    /// Orders for `ids` in this order, reusing `previous` wherever it's still increasing.
    public static func assign(_ ids: [UUID], previous: [UUID: Int]) -> [UUID: Int] {
        let kept = keptIndices(ids.map { previous[$0] })
        var result: [UUID: Int] = [:]
        var index = 0
        while index < ids.count {
            if kept.contains(index) {
                result[ids[index]] = previous[ids[index]]!
                index += 1
                continue
            }
            // A run of items needing orders, between the kept neighbours on either side.
            let start = index
            while index < ids.count, !kept.contains(index) { index += 1 }
            let count = index - start
            let low = start > 0 ? result[ids[start - 1]] : nil
            let high = index < ids.count ? previous[ids[index]] : nil
            guard let fresh = fill(count: count, low: low, high: high) else {
                return renumbered(ids)
            }
            for (offset, order) in fresh.enumerated() { result[ids[start + offset]] = order }
        }
        return result
    }

    /// `items` sorted by `orders`, ties broken by id. An item with no order stays right
    /// after the item before it, so local items not yet uploaded don't jump.
    public static func arrange<T>(_ items: [T], id: (T) -> UUID, orders: [UUID: Int]) -> [T] {
        var anchor = Int.min
        let keyed = items.enumerated().map { index, item -> (item: T, order: Int, local: Int, tie: String) in
            let itemId = id(item)
            if let order = orders[itemId] {
                anchor = order
                return (item, order, 0, itemId.uuidString)
            }
            return (item, anchor, 1, String(format: "%012d", index))
        }
        return keyed.sorted { a, b in
            if a.order != b.order { return a.order < b.order }
            if a.local != b.local { return a.local < b.local }
            return a.tie < b.tie
        }.map(\.item)
    }

    /// Orders to arrange local `levels` (each a sibling list in its current order) after a
    /// fetch: the local order expressed against `known` (the latest server orders), with
    /// `fetched` orders winning for the records that just arrived.
    public static func merge(levels: [[UUID]], known: [UUID: Int], fetched: [UUID: Int]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for level in levels {
            let unfetched = level.filter { fetched[$0] == nil }
            result.merge(assign(unfetched, previous: known)) { _, new in new }
        }
        result.merge(fetched) { _, new in new }
        return result
    }

    // MARK: - Helpers

    /// Indices of a longest strictly increasing run among the known values.
    private static func keptIndices(_ values: [Int?]) -> Set<Int> {
        var length = [Int](repeating: 0, count: values.count)
        var parent = [Int?](repeating: nil, count: values.count)
        var best: Int?
        for i in values.indices {
            guard let value = values[i] else { continue }
            length[i] = 1
            for j in 0..<i {
                if let earlier = values[j], earlier < value, length[j] + 1 > length[i] {
                    length[i] = length[j] + 1
                    parent[i] = j
                }
            }
            if best == nil || length[i] > length[best!] { best = i }
        }
        var kept: Set<Int> = []
        var cursor = best
        while let i = cursor {
            kept.insert(i)
            cursor = parent[i]
        }
        return kept
    }

    /// `count` increasing orders strictly between `low` and `high`, or nil if there's no room.
    private static func fill(count: Int, low: Int?, high: Int?) -> [Int]? {
        switch (low, high) {
        case (nil, nil):
            return (1...count).map { $0 * spacing }
        case (let low?, nil):
            return (1...count).map { low + $0 * spacing }
        case (nil, let high?):
            return (1...count).map { high - (count + 1 - $0) * spacing }
        case (let low?, let high?):
            let step = (high - low) / (count + 1)
            guard step >= 1 else { return nil }
            return (1...count).map { low + $0 * step }
        }
    }

    private static func renumbered(_ ids: [UUID]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, ($0 + 1) * spacing) })
    }
}
