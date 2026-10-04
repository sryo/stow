import XCTest
import CoreGraphics
@testable import StowIOS

/// Row swipe actions and workspace paging share the same horizontal drag.
final class RowSwipeTests: XCTestCase {

    func testRowActionsNeverFireOnAFullSwipe() {
        XCTAssertFalse(RowSwipe.allowsFullSwipe, "a paging swipe must not archive or open a row")
    }

    func testAFastHorizontalSwipeOnARowPages() {
        XCTAssertTrue(PagerSwipe.pages(velocity: CGPoint(x: -900, y: 20), startsOnRow: true))
        XCTAssertTrue(PagerSwipe.pages(velocity: CGPoint(x: 700, y: -40), startsOnRow: true))
    }

    func testASlowHorizontalDragOnARowRevealsItsActions() {
        XCTAssertFalse(PagerSwipe.pages(velocity: CGPoint(x: -150, y: 5), startsOnRow: true))
        XCTAssertFalse(PagerSwipe.pages(velocity: CGPoint(x: 120, y: 0), startsOnRow: true))
    }

    func testAnyHorizontalDragOffARowPages() {
        XCTAssertTrue(PagerSwipe.pages(velocity: CGPoint(x: -60, y: 0), startsOnRow: false))
        XCTAssertTrue(PagerSwipe.pages(velocity: CGPoint(x: 900, y: 0), startsOnRow: false))
    }
}
