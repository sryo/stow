import XCTest
@testable import StowCore

final class WorkspaceStripLayoutTests: XCTestCase {
    private let names = ["Personal", "Engineering", "Side projects", "Reading", "Home", "Travel", "Music", "Finance", "Health", "Archive"]

    /// Deterministic text widths: 7pt per character (semibold 7.5).
    private func measure(_ s: String, _ w: NSFont.Weight) -> CGFloat {
        CGFloat(s.count) * (w == .semibold ? 7.5 : 7)
    }

    private func items(_ n: Int) -> [WorkspaceStripLayout.Item] {
        var items = names.prefix(n).map { WorkspaceStripLayout.Item(id: UUID(), name: $0) }
        WorkspaceStripLayout.assignMonograms(&items)
        return items
    }

    private func layout(_ n: Int, width: CGFloat, page: Int) -> WorkspaceStripLayout {
        let it = items(n)
        return WorkspaceStripLayout.rest(width: width, items: it, metrics: WorkspaceStripLayout.metrics(for: it, measure: measure), page: page, previous: nil)
    }

    func testFewWorkspacesShowFullNames() {
        let l = layout(2, width: 324, page: 1)
        XCTAssertEqual(l.tabs.map(\.tier), [.selected, .full])
        XCTAssertEqual(l.overflow.count, 0)
    }

    func testSelectedNameIsNeverCompressed() {
        for n in 2...10 {
            for page in 1...n {
                let l = layout(n, width: 324, page: page)
                XCTAssertEqual(l.tabs[page - 1].tier, .selected)
            }
        }
    }

    func testNeverOverflowsTheWidth() {
        for n in 2...10 {
            for w: CGFloat in [264, 324, 504] {
                for page in 0...(n + 1) {
                    let l = layout(n, width: w, page: page)
                    XCTAssertLessThanOrEqual(l.used, w + 0.5, "n=\(n) w=\(w) page=\(page)")
                }
            }
        }
    }

    func testFarthestTabsBecomeChipsFirst() {
        let l = layout(8, width: 324, page: 1)
        let chips = l.tabs.enumerated().filter { $0.element.tier == .chip }.map(\.offset)
        XCTAssertFalse(chips.isEmpty)
        // Chips sit at the far end from the selected first tab.
        XCTAssertEqual(chips.max(), 7)
    }

    func testOverflowListsHiddenWorkspaces() {
        let l = layout(10, width: 264, page: 1)
        XCTAssertEqual(l.overflow.count, l.overflow.hiddenIds.count)
        XCTAssertEqual(l.tabs.filter { $0.tier == .hidden }.count, l.overflow.count)
    }

    func testMonogramsAreUnique() {
        var it = ["Side projects", "Settings", "Personal", "Projects", "Photos"].map { WorkspaceStripLayout.Item(id: UUID(), name: $0) }
        WorkspaceStripLayout.assignMonograms(&it)
        XCTAssertEqual(Set(it.map(\.monogram)).count, it.count, it.map(\.monogram).description)
    }

    func testLerpBlendsSelection() {
        let it = items(4)
        let m = WorkspaceStripLayout.metrics(for: it, measure: measure)
        let a = WorkspaceStripLayout.rest(width: 324, items: it, metrics: m, page: 1, previous: nil)
        let b = WorkspaceStripLayout.rest(width: 324, items: it, metrics: m, page: 2, previous: nil)
        let mid = WorkspaceStripLayout.lerp(a, b, 0.5)
        XCTAssertEqual(mid.tabs[0].selection, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.tabs[1].selection, 0.5, accuracy: 0.001)
    }
}
