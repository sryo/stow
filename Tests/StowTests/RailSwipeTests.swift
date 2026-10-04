import XCTest
@testable import StowCore

/// While swiping between workspaces on the rail, the outgoing items slide away with the
/// finger and the incoming workspace's items slide in from the side it comes from.
final class RailSwipeTests: XCTestCase {
    func testNoProgressLeavesOutgoingInPlaceAndIncomingOffscreen() {
        let t = RailSwipe.translations(delta: 0, direction: 1, width: 52)
        XCTAssertEqual(t.outgoing, 0)
        XCTAssertEqual(t.incoming, 52)
    }

    func testSwipingForwardMovesBothLeft() {
        let t = RailSwipe.translations(delta: 0.25, direction: 1, width: 52)
        XCTAssertEqual(t.outgoing, -13)
        XCTAssertEqual(t.incoming, 39)
    }

    func testSwipingBackComesInFromTheLeft() {
        let t = RailSwipe.translations(delta: -0.5, direction: -1, width: 52)
        XCTAssertEqual(t.outgoing, 26)
        XCTAssertEqual(t.incoming, -26)
    }

    func testFullSwipeLandsIncomingInPlace() {
        let t = RailSwipe.translations(delta: 1, direction: 1, width: 52)
        XCTAssertEqual(t.outgoing, -52)
        XCTAssertEqual(t.incoming, 0)
    }

    // Pages: 0 is Settings, 1...n the workspaces, n+1 the add-new page.
    func testWorkspaceIndexForPage() {
        XCTAssertNil(RailSwipe.workspaceIndex(forPage: 0, workspaceCount: 3))
        XCTAssertEqual(RailSwipe.workspaceIndex(forPage: 1, workspaceCount: 3), 0)
        XCTAssertEqual(RailSwipe.workspaceIndex(forPage: 3, workspaceCount: 3), 2)
        XCTAssertNil(RailSwipe.workspaceIndex(forPage: 4, workspaceCount: 3))
        XCTAssertNil(RailSwipe.workspaceIndex(forPage: -1, workspaceCount: 3))
    }
}
