import AppKit

/// Pure layout for the workspace tab strip: every workspace is a segment of one row.
///
/// The current workspace is a pill with its full name. Others compress in tiers as the
/// window narrows: full name → tail-truncated name (≥4 characters, widths water-filled)
/// → two-letter monogram chip → hidden behind a "+n" overflow. Chips are taken from the
/// workspaces farthest from the current one first. A swipe blends two layouts with
/// `lerp`, so the strip morphs frame by frame.
struct WorkspaceStripLayout {
    struct Item: Equatable {
        let id: UUID
        let name: String
        var monogram: String = ""
    }

    enum Tier { case selected, full, truncated, chip, hidden }

    struct Tab {
        let id: UUID
        var x: CGFloat
        var width: CGFloat
        var alpha: CGFloat
        /// 0…1, how much the tab wears the selected pill.
        var selection: CGFloat
        var nameAlpha: CGFloat
        var monogramAlpha: CGFloat
        var leftRadius: CGFloat
        var rightRadius: CGFloat
        var tier: Tier
    }

    struct Overflow {
        var x: CGFloat
        var width: CGFloat
        var alpha: CGFloat
        var count: Int
        /// Hidden workspaces, in order, for the overflow menu.
        var hiddenIds: [UUID]
    }

    /// Remembers the previous rest layout so the tier only changes with 8pt of hysteresis.
    struct Memory: Equatable {
        var level: Int
        var runStart: Int
        var selected: Int
        var count: Int
    }

    var tabs: [Tab]
    var overflow: Overflow
    /// 0…1 selection of the Settings (page 0) and "+" (last page) controls.
    var settingsSelection: CGFloat
    var plusSelection: CGFloat
    var level: Int
    var runStart: Int
    var selected: Int
    var count: Int
    var used: CGFloat

    var memory: Memory { Memory(level: level, runStart: runStart, selected: selected, count: count) }

    // MARK: - Metrics

    enum K {
        static let tabHeight: CGFloat = 24
        static let unselectedPadding: CGFloat = 9
        static let selectedPaddingLeft: CGFloat = 8
        static let dot: CGFloat = 8
        static let dotGap: CGFloat = 5
        static let selectedPaddingRight: CGFloat = 9
        static let chipMin: CGFloat = 24
        static let chipPadding: CGFloat = 8
        static let gapAroundSelected: CGFloat = 4
        /// Adjacent unselected segments overlap by 1pt so their borders merge.
        static let overlap: CGFloat = -1
        static let radius: CGFloat = 7
        static let overflowMin: CGFloat = 26
        static let overflowPadding: CGFloat = 10
        static let hysteresis: CGFloat = 8
    }

    struct Metrics {
        let full: CGFloat
        let selected: CGFloat
        let minTruncated: CGFloat
        let chip: CGFloat
    }

    /// Width of a label showing `text`, including the text field's own 2pt insets.
    static func textWidth(_ text: String, weight: NSFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)]).width) + 4
    }

    static func metrics(for items: [Item], measure: (String, NSFont.Weight) -> CGFloat = textWidth) -> [Metrics] {
        items.map { item in
            let full = measure(item.name, .medium) + 2 * K.unselectedPadding
            let short = item.name.count <= 5 ? item.name : String(item.name.prefix(4)).trimmingCharacters(in: .whitespaces) + "…"
            return Metrics(
                full: full,
                selected: measure(item.name, .semibold) + K.selectedPaddingLeft + K.dot + K.dotGap + K.selectedPaddingRight,
                minTruncated: min(full, measure(short, .medium) + 2 * K.unselectedPadding),
                chip: max(K.chipMin, ceil(measure(item.monogram, .semibold)) + K.chipPadding)
            )
        }
    }

    /// One or two letters per workspace, unique where first letters collide (`WorkspaceMonogram`).
    static func assignMonograms(_ items: inout [Item]) {
        let letters = WorkspaceMonogram.assign(items.map { ($0.id, $0.name) })
        for i in items.indices { items[i].monogram = letters[items[i].id] ?? "?" }
    }

    // MARK: - Rest layout

    private struct Placement {
        var frames: [(x: CGFloat, width: CGFloat, hidden: Bool)]
        var used: CGFloat
        var overflow: (x: CGFloat, width: CGFloat)?
    }

    private static func place(count: Int, selected: Int, width: (Int) -> CGFloat?, overflowWidth: CGFloat) -> Placement {
        var x: CGFloat = 0
        var previous: Int?
        var frames: [(CGFloat, CGFloat, Bool)] = []
        for i in 0..<count {
            guard let w = width(i) else {
                frames.append((x, 0, true))
                continue
            }
            if let p = previous { x += (p == selected || i == selected) ? K.gapAroundSelected : K.overlap }
            frames.append((x, w, false))
            x += w
            previous = i
        }
        var overflow: (CGFloat, CGFloat)?
        if overflowWidth > 0 {
            x += previous != nil ? K.gapAroundSelected : 0
            overflow = (x, overflowWidth)
            x += overflowWidth
        }
        return Placement(frames: frames, used: x, overflow: overflow)
    }

    /// The largest equal cap such that capped widths sum to `budget`.
    private static func waterfill(_ widths: [CGFloat], budget: CGFloat) -> CGFloat {
        let sorted = widths.sorted()
        var remaining = budget
        for (i, w) in sorted.enumerated() {
            let cap = remaining / CGFloat(sorted.count - i)
            if w >= cap { return cap }
            remaining -= w
        }
        return .infinity
    }

    /// The layout at rest on `page` (0 = Settings, 1…N = workspaces, N+1 = "+").
    static func rest(width: CGFloat, items: [Item], metrics m: [Metrics], page: Int,
                     previous: Memory?, editingWidth: CGFloat? = nil) -> WorkspaceStripLayout {
        let n = items.count
        let sel = (page >= 1 && page <= n) ? page - 1 : -1
        let others = (0..<n).filter { $0 != sel }
        // Farthest from the selection compress first.
        let compressionOrder = others.sorted { a, b in
            let da = sel < 0 ? a : abs(a - sel), db = sel < 0 ? b : abs(b - sel)
            return da != db ? da > db : a > b
        }
        let mCount = others.count
        let maxLevel = 1 + 2 * mCount
        let selectedWidth = sel >= 0 ? (editingWidth ?? m[sel].selected) : 0

        struct Attempt { var level: Int; var placement: Placement; var chips: Set<Int>; var hidden: Set<Int>; var hiddenCount: Int; var runStart: Int }

        func attempt(_ level: Int, _ budgetWidth: CGFloat, force: Bool) -> Attempt? {
            var chips = Set<Int>(), hidden = Set<Int>()
            if level >= 2 { compressionOrder.prefix(min(level - 1, mCount)).forEach { chips.insert($0) } }
            let hiddenCount = level > 1 + mCount ? level - 1 - mCount : 0
            var runStart = 0
            if hiddenCount > 0 {
                let visible = n - hiddenCount
                var s = previous?.runStart ?? 0
                if sel >= 0 { s = min(max(s, sel - (visible - 1)), sel) }
                s = max(0, min(s, hiddenCount))
                runStart = s
                for i in 0..<n where i < s || i >= s + visible { hidden.insert(i) }
            }
            let overflowWidth = hiddenCount > 0 ? max(K.overflowMin, ceil(textWidth("+\(hiddenCount)", weight: .semibold)) + K.overflowPadding) : 0
            let named = others.filter { !chips.contains($0) && !hidden.contains($0) }
            let fixed = place(count: n, selected: sel, width: { i in
                hidden.contains(i) ? nil : (i == sel ? selectedWidth : (chips.contains(i) ? m[i].chip : 0))
            }, overflowWidth: overflowWidth)
            let remaining = budgetWidth - fixed.used
            var cap = CGFloat.infinity
            if !named.isEmpty {
                let fulls = named.map { m[$0].full }
                if fulls.reduce(0, +) > remaining {
                    if level < 1 && !force { return nil }
                    cap = waterfill(fulls, budget: remaining)
                    if !force && named.contains(where: { min(m[$0].full, cap) < m[$0].minTruncated - 0.01 }) { return nil }
                }
            } else if remaining < -0.01 && !force {
                return nil
            }
            let placement = place(count: n, selected: sel, width: { i in
                if hidden.contains(i) { return nil }
                if i == sel { return selectedWidth }
                if chips.contains(i) { return m[i].chip }
                return max(m[i].minTruncated, min(m[i].full, cap))
            }, overflowWidth: overflowWidth)
            if !force && placement.used > budgetWidth + 0.01 { return nil }
            return Attempt(level: level, placement: placement, chips: chips, hidden: hidden, hiddenCount: hiddenCount, runStart: runStart)
        }

        func fit(_ w: CGFloat) -> Attempt {
            for level in 0...maxLevel {
                if let a = attempt(level, w, force: false) { return a }
            }
            return attempt(maxLevel, w, force: true)!
        }

        var r = fit(width)
        // Hysteresis: don't relax to a roomier tier until there's 8pt to spare.
        if let previous, previous.selected == sel, previous.count == n, r.level < previous.level {
            let tighter = fit(width - K.hysteresis)
            let level = max(r.level, min(previous.level, tighter.level))
            if level != r.level, let a = attempt(level, width, force: false) { r = a }
        }

        let visible = (0..<n).filter { !r.hidden.contains($0) }
        var tabs: [Tab] = []
        for i in 0..<n {
            let f = r.placement.frames[i]
            let isHidden = r.hidden.contains(i), isSelected = i == sel, isChip = r.chips.contains(i)
            let vi = visible.firstIndex(of: i)
            let previousVisible = vi.flatMap { $0 > 0 ? visible[$0 - 1] : nil }
            let nextVisible = vi.flatMap { $0 < visible.count - 1 ? visible[$0 + 1] : nil }
            // Segments touching another unselected segment share a square edge.
            let leftRadius = isSelected ? K.radius : ((previousVisible != nil && previousVisible != sel) ? 0 : K.radius)
            let rightRadius = isSelected ? K.radius : ((nextVisible != nil && nextVisible != sel) ? 0 : K.radius)
            let tier: Tier = isHidden ? .hidden : isSelected ? .selected : isChip ? .chip : (f.width < m[i].full - 0.5 ? .truncated : .full)
            tabs.append(Tab(id: items[i].id, x: f.x, width: f.width, alpha: isHidden ? 0 : 1, selection: isSelected ? 1 : 0,
                            nameAlpha: (isHidden || isChip) ? 0 : 1, monogramAlpha: (isChip && !isHidden) ? 1 : 0,
                            leftRadius: leftRadius, rightRadius: rightRadius, tier: tier))
        }
        let hiddenIds = (0..<n).filter { r.hidden.contains($0) }.map { items[$0].id }
        let overflow = r.placement.overflow.map { Overflow(x: $0.x, width: $0.width, alpha: 1, count: r.hiddenCount, hiddenIds: hiddenIds) }
            ?? Overflow(x: width, width: 0, alpha: 0, count: 0, hiddenIds: [])
        return WorkspaceStripLayout(tabs: tabs, overflow: overflow,
                                    settingsSelection: page == 0 ? 1 : 0, plusSelection: page == n + 1 ? 1 : 0,
                                    level: r.level, runStart: r.runStart, selected: sel, count: n, used: r.placement.used)
    }

    // MARK: - Swipe blending

    static func lerp(_ a: WorkspaceStripLayout, _ b: WorkspaceStripLayout, _ t: CGFloat) -> WorkspaceStripLayout {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        let byId = Dictionary(uniqueKeysWithValues: b.tabs.map { ($0.id, $0) })
        let tabs = a.tabs.map { ta -> Tab in
            let tb = byId[ta.id] ?? ta
            return Tab(id: ta.id, x: mix(ta.x, tb.x), width: mix(ta.width, tb.width), alpha: mix(ta.alpha, tb.alpha),
                       selection: mix(ta.selection, tb.selection), nameAlpha: mix(ta.nameAlpha, tb.nameAlpha),
                       monogramAlpha: mix(ta.monogramAlpha, tb.monogramAlpha), leftRadius: mix(ta.leftRadius, tb.leftRadius),
                       rightRadius: mix(ta.rightRadius, tb.rightRadius), tier: t < 0.5 ? ta.tier : tb.tier)
        }
        let o = Overflow(x: mix(a.overflow.x, b.overflow.x), width: mix(a.overflow.width, b.overflow.width),
                         alpha: mix(a.overflow.alpha, b.overflow.alpha),
                         count: t < 0.5 ? (a.overflow.count > 0 ? a.overflow.count : b.overflow.count) : (b.overflow.count > 0 ? b.overflow.count : a.overflow.count),
                         hiddenIds: t < 0.5 ? a.overflow.hiddenIds : b.overflow.hiddenIds)
        return WorkspaceStripLayout(tabs: tabs, overflow: o,
                                    settingsSelection: mix(a.settingsSelection, b.settingsSelection),
                                    plusSelection: mix(a.plusSelection, b.plusSelection),
                                    level: t < 0.5 ? a.level : b.level, runStart: t < 0.5 ? a.runStart : b.runStart,
                                    selected: t < 0.5 ? a.selected : b.selected, count: a.count, used: mix(a.used, b.used))
    }
}
