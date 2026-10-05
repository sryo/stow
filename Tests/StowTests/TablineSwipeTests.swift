import AppKit
import XCTest
@testable import StowCore

/// A two-finger swipe over the Tabline pages workspaces like the window does: the tabs
/// follow the fingers, the next workspace's slide in, and letting go settles on one.
@MainActor
final class TablineSwipeTests: XCTestCase {
    func testTheOffsetNamesTheNeighbourAndHowFarAlong() {
        XCTAssertEqual(TablinePaging.swipe(offset: 1.25, current: 1, count: 3), .init(progress: 0.25, neighbor: 2))
        XCTAssertEqual(TablinePaging.swipe(offset: 0.6, current: 1, count: 3), .init(progress: -0.4, neighbor: 0))
        XCTAssertEqual(TablinePaging.swipe(offset: 2.25, current: 2, count: 3), .init(progress: 0.25, neighbor: nil),
                       "past the last there's no neighbour; it rubber-bands")
        XCTAssertNil(TablinePaging.swipe(offset: 1, current: 1, count: 3), "at rest, no swipe")
    }

    func testAPagerOnlyTakesSwipesOverItsOwnWindow() {
        let pager = ScrollWheelPageController()
        let mine = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 40), styleMask: [], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 40), styleMask: [], backing: .buffered, defer: true)
        pager.attach(to: mine)
        defer { pager.detach() }
        XCTAssertTrue(pager.handles(window: mine))
        XCTAssertFalse(pager.handles(window: other), "a swipe over the Tabline doesn't page the window behind it")
    }

    func testTheStripSlidesWhileSwipingAndSettlesAfter() {
        let strip = TablineStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        var current = TablineStripModel()
        current.name = "Work"
        strip.update(current)
        var next = TablineStripModel()
        next.name = "Home"
        next.colorId = WorkspaceColorId.allCases[3]
        strip.showSwipe(progress: 0.3, neighbor: next)
        XCTAssertEqual(strip.swipeProgress, 0.3)
        XCTAssertEqual(strip.accessibilityLabel(), "Tabline, Work", "under half way it's still Work")
        strip.showSwipe(progress: 0.7, neighbor: next)
        XCTAssertEqual(strip.accessibilityLabel(), "Tabline, Home", "past half way the incoming one leads")
        strip.endSwipe()
        XCTAssertNil(strip.swipeProgress)
        XCTAssertEqual(strip.accessibilityLabel(), "Tabline, Work")
    }
}
