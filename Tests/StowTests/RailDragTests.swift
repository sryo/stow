import AppKit
import XCTest
@testable import StowCore
import StowShared

final class RailDragTests: XCTestCase {
    private func cells(_ count: Int) -> [NSRect] {
        (0..<count).map { NSRect(x: 7, y: CGFloat($0) * 40, width: 38, height: 38) }
    }

    // MARK: - target slot

    func testTargetSlot_beforeFirstMidpointIsZero() {
        XCTAssertEqual(RailDrag.targetSlot(dragY: 10, cellFrames: cells(3)), 0)
        XCTAssertEqual(RailDrag.targetSlot(dragY: -30, cellFrames: cells(3)), 0)
    }

    func testTargetSlot_pastMidpointMovesToNextGap() {
        XCTAssertEqual(RailDrag.targetSlot(dragY: 25, cellFrames: cells(3)), 1)
        XCTAssertEqual(RailDrag.targetSlot(dragY: 65, cellFrames: cells(3)), 2)
    }

    func testTargetSlot_belowLastIsEnd() {
        XCTAssertEqual(RailDrag.targetSlot(dragY: 500, cellFrames: cells(3)), 3)
    }

    // MARK: - model index

    private let l1 = UUID(), t1 = UUID(), l2 = UUID(), s1 = UUID(), l3 = UUID()
    private var items: [UUID] { [l1, t1, l2, s1, l3] }
    private var rail: [UUID] { [l1, l2, l3] }

    func testModelIndex_movingToTopIsZero() {
        XCTAssertEqual(RailDrag.modelIndex(forSlot: 0, moving: l3, railIds: rail, itemIds: items), 0)
    }

    func testModelIndex_beforeARailItemLandsBeforeItInItems() {
        // Before L3, which sits at items[4], past the snippet the rail doesn't show.
        XCTAssertEqual(RailDrag.modelIndex(forSlot: 2, moving: l1, railIds: rail, itemIds: items), 4)
    }

    func testModelIndex_endLandsAfterLastRailItem() {
        XCTAssertEqual(RailDrag.modelIndex(forSlot: 3, moving: l1, railIds: rail, itemIds: items), 5)
    }

    func testModelIndex_droppingInPlaceIsNoMove() {
        XCTAssertNil(RailDrag.modelIndex(forSlot: 1, moving: l2, railIds: rail, itemIds: items))
        XCTAssertNil(RailDrag.modelIndex(forSlot: 2, moving: l2, railIds: rail, itemIds: items))
    }

    // MARK: - workspace drop

    func testWorkspaceDrop_hitsAnotherWorkspacesDot() {
        let current = UUID(), other = UUID()
        let dots = [(current, NSRect(x: 20, y: 14, width: 12, height: 12)),
                    (other, NSRect(x: 20, y: 32, width: 12, height: 12))]
        XCTAssertEqual(RailDrag.workspaceDrop(at: NSPoint(x: 26, y: 38), dots: dots, current: current), other)
    }

    func testWorkspaceDrop_toleratesNearMissesAroundSmallDots() {
        let current = UUID(), other = UUID()
        let dots = [(current, NSRect(x: 20, y: 14, width: 12, height: 12)),
                    (other, NSRect(x: 20, y: 32, width: 12, height: 12))]
        XCTAssertEqual(RailDrag.workspaceDrop(at: NSPoint(x: 14, y: 46), dots: dots, current: current), other)
    }

    func testWorkspaceDrop_currentWorkspaceAndEmptySpaceAreNil() {
        let current = UUID(), other = UUID()
        let dots = [(current, NSRect(x: 20, y: 14, width: 12, height: 12)),
                    (other, NSRect(x: 20, y: 32, width: 12, height: 12))]
        XCTAssertNil(RailDrag.workspaceDrop(at: NSPoint(x: 26, y: 20), dots: dots, current: current))
        XCTAssertNil(RailDrag.workspaceDrop(at: NSPoint(x: 26, y: 200), dots: dots, current: current))
    }

    // MARK: - text drop index

    func testTextDropIndex_beforeARailItemLandsBeforeItInItems() {
        XCTAssertEqual(RailDrag.textDropIndex(forSlot: 0, railIds: rail, itemIds: items), 0)
        XCTAssertEqual(RailDrag.textDropIndex(forSlot: 2, railIds: rail, itemIds: items), 4)
    }

    func testTextDropIndex_endLandsAfterTheLastRailItemAndAnEmptyRailAtTheTop() {
        XCTAssertEqual(RailDrag.textDropIndex(forSlot: 3, railIds: rail, itemIds: items), 5)
        XCTAssertEqual(RailDrag.textDropIndex(forSlot: 0, railIds: [], itemIds: [t1, s1]), 0)
    }

    // MARK: - workspace target (tabs)

    func testWorkspaceTarget_takesTheTabUnderThePointerWithoutTolerance() {
        let current = UUID(), other = UUID()
        let tabs = [(current, NSRect(x: 0, y: 0, width: 100, height: 26)), (other, NSRect(x: 102, y: 0, width: 60, height: 26))]
        XCTAssertEqual(RailDrag.workspaceTarget(at: NSPoint(x: 130, y: 13), targets: tabs, current: current), other)
        XCTAssertNil(RailDrag.workspaceTarget(at: NSPoint(x: 50, y: 13), targets: tabs, current: current))
        XCTAssertNil(RailDrag.workspaceTarget(at: NSPoint(x: 165, y: 13), targets: tabs, current: current))
    }
}
