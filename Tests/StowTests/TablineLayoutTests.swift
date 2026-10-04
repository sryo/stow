import XCTest
@testable import StowCore

/// The strip's layout as a pure function of measured widths: the gear before the chip,
/// the three tiers, and spare width handed back as titles once only icons fit.
final class TablineLayoutTests: XCTestCase {
    private typealias W = TablineLayout.EntryWidths

    private func input(width: CGFloat, entries: Int, raised: Int? = nil,
                       entry: W = W(full: 110, short: 84, icon: 24)) -> TablineLayout.Input {
        TablineLayout.Input(width: width, gearWidth: 24, chipWidth: 100,
                            entries: Array(repeating: entry, count: entries), raisedIndex: raised,
                            ghost: nil, pocket: nil, overflowWidth: { 6 + CGFloat("+\($0)".count) * 7 + 6 })
    }

    private func item(_ layout: TablineLayout, _ kind: TablineStripView.Kind) -> TablineLayout.Item? {
        layout.items.first { $0.kind == kind }
    }

    func testGearLeadsTheStripBeforeTheChip() {
        let layout = TablineLayout.make(input(width: 1100, entries: 3))
        let gear = try! XCTUnwrap(item(layout, .gear))
        let chip = try! XCTUnwrap(item(layout, .chip))
        XCTAssertEqual(layout.items.first?.kind, .gear, "the gear is the first part, like the rail's gear above its dots")
        XCTAssertEqual(gear.x, TablineLayout.pad)
        XCTAssertEqual(gear.width, 24)
        XCTAssertLessThanOrEqual(gear.x + gear.width, chip.x)
        XCTAssertGreaterThan(item(layout, .tab(0))!.x, chip.x + chip.width)
    }

    func testFullTierWhenEverythingFits() {
        let layout = TablineLayout.make(input(width: 1100, entries: 5))
        XCTAssertEqual(layout.tier, .full)
        XCTAssertTrue(layout.hiddenEntryIndices.isEmpty)
        XCTAssertEqual(item(layout, .tab(0))?.width, 110)
    }

    func testIconTierHandsSpareWidthBackAsTitles() {
        // 19 entries in 1650pt: short names (19 × 84) don't fit, so the strip is in the
        // icon tier, but most of the width is still free.
        let layout = TablineLayout.make(input(width: 1650, entries: 19, raised: 7))
        XCTAssertEqual(layout.tier, .icon)
        XCTAssertTrue(layout.hiddenEntryIndices.isEmpty)
        let tabs = layout.items.filter { if case .tab = $0.kind { return true }; return false }
        XCTAssertEqual(tabs.count, 19)
        let titled = tabs.filter { $0.tier != .icon }
        XCTAssertGreaterThan(titled.count, 9, "as many tabs as fit get a title")
        XCTAssertLessThan(titled.count, 19)
        XCTAssertEqual(item(layout, .tab(7))?.tier, .short, "the raised page is titled first")
        XCTAssertEqual(tabs.first?.tier, .short, "then the tabs in order")
        XCTAssertEqual(tabs.last?.tier, .icon)
        let end = tabs.last.map { $0.x + $0.width } ?? 0
        XCTAssertGreaterThan(end, 1650 * 0.9, "the strip fills instead of leaving half of it empty")
        XCTAssertLessThanOrEqual(end, 1650 - TablineLayout.pad)
    }

    func testIconTierWaterfillNeverOverlapsAndKeepsOrder() {
        let layout = TablineLayout.make(input(width: 1650, entries: 19, raised: 7))
        for (a, b) in zip(layout.items, layout.items.dropFirst()) {
            XCTAssertLessThanOrEqual(a.x + a.width, b.x, "\(a.kind) overlaps \(b.kind)")
        }
    }

    func testOverflowLeavesNoSpareToWaterfill() {
        let layout = TablineLayout.make(input(width: 400, entries: 19))
        XCTAssertEqual(layout.tier, .icon)
        XCTAssertFalse(layout.hiddenEntryIndices.isEmpty)
        XCTAssertNotNil(item(layout, .overflow))
        XCTAssertTrue(layout.items.allSatisfy { $0.tier == .icon || $0.kind == .chip || $0.kind == .gear || $0.kind == .overflow })
    }

    func testShortTierStillWaterfillsTowardFullNames() {
        // 5 × 110 + gaps doesn't fit, 5 × 84 does: names shorten only as far as needed.
        let layout = TablineLayout.make(input(width: 680, entries: 5))
        XCTAssertEqual(layout.tier, .short)
        let widths = (0..<5).compactMap { item(layout, .tab($0))?.width }
        XCTAssertTrue(widths.allSatisfy { $0 > 84 && $0 <= 110 }, "widths: \(widths)")
    }
}
