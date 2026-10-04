import XCTest
@testable import StowCore

/// Where the Tabline sits for each edge, on the 1710×1112 main display with a 37pt menu
/// bar (AppKit coordinates, y up). Height 32, gap 3.
final class TablinePlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1710, height: 1112)
    private let visible = NSRect(x: 0, y: 0, width: 1710, height: 1075)
    private let floating = NSRect(x: 300, y: 200, width: 1000, height: 700)

    private func place(_ edge: TablineEdge, _ window: NSRect, fullScreen: Bool = false,
                       nudged: Bool = false, peeking: Bool = false) -> TablinePlacement {
        TablinePlacement.place(edge: edge, window: window, isFullScreen: fullScreen, screen: screen,
                               visible: visible, safeAreaTop: fullScreen ? 37 : 0,
                               alreadyNudged: nudged, peeking: peeking)
    }

    // MARK: Top (today's behaviour)

    func testTopRidesThreePointsAboveAFloatingWindow() {
        let p = place(.top, floating)
        XCTAssertEqual(p.dock, .above)
        XCTAssertEqual(p.frame, NSRect(x: 300, y: 903, width: 1000, height: 32))
        XCTAssertFalse(p.wantsNudge)
    }

    func testTopGoesBelowWhenThereIsNoRoomAbove() {
        let p = place(.top, NSRect(x: 300, y: 200, width: 1000, height: 860))
        XCTAssertEqual(p.dock, .below)
        XCTAssertEqual(p.frame, NSRect(x: 300, y: 165, width: 1000, height: 32))
    }

    func testTopMakesABandForAMaximizedWindow() {
        let p = place(.top, visible)
        XCTAssertEqual(p.dock, .band)
        XCTAssertTrue(p.wantsNudge, "the window is nudged down to make room")
        XCTAssertEqual(p.frame, NSRect(x: 4, y: 1040, width: 1702, height: 32))
        let already = place(.top, NSRect(x: 0, y: 0, width: 1710, height: 1037), nudged: true)
        XCTAssertEqual(already.dock, .band)
        XCTAssertFalse(already.wantsNudge)
        XCTAssertEqual(already.frame, p.frame)
    }

    func testTopIsALipInFullScreenThatPeeksOnHover() {
        let lip = place(.top, screen, fullScreen: true)
        XCTAssertEqual(lip.dock, .lip)
        XCTAssertEqual(lip.frame, NSRect(x: 245, y: 1068, width: 1220, height: 5))
        let peek = place(.top, screen, fullScreen: true, peeking: true)
        XCTAssertEqual(peek.dock, .peek)
        XCTAssertEqual(peek.frame, NSRect(x: 245, y: 1037, width: 1220, height: 32))
        XCTAssertEqual(peek.lipFrame, lip.frame)
    }

    func testTopIsTheDefaultEdge() {
        XCTAssertEqual(TablineEdge(stored: nil), .top)
        XCTAssertEqual(TablineEdge(stored: "bottom"), .bottom)
        XCTAssertEqual(TablineEdge(stored: "sideways"), .top)
    }

    // MARK: Bottom

    func testBottomRidesThreePointsBelowAFloatingWindow() {
        let p = place(.bottom, floating)
        XCTAssertEqual(p.dock, .below)
        XCTAssertEqual(p.frame, NSRect(x: 300, y: 165, width: 1000, height: 32))
        XCTAssertFalse(p.wantsNudge)
    }

    func testBottomKeepsAMinimumWidthLikeTheTop() {
        let narrow = NSRect(x: 300, y: 200, width: 120, height: 500)
        XCTAssertEqual(place(.bottom, narrow).frame.width, 200)
    }

    func testBottomSitsInsideTheBottomEdgeOfAMaximizedWindow() {
        let p = place(.bottom, visible)
        XCTAssertEqual(p.dock, .inside)
        XCTAssertEqual(p.frame, NSRect(x: 4, y: 3, width: 1702, height: 32))
        XCTAssertFalse(p.wantsNudge, "the bottom never moves the window")
    }

    func testBottomSitsInsideWhenTheWindowTouchesTheScreenBottom() {
        let low = NSRect(x: 300, y: 20, width: 1000, height: 700)
        let p = place(.bottom, low)
        XCTAssertEqual(p.dock, .inside)
        XCTAssertEqual(p.frame, NSRect(x: 304, y: 23, width: 992, height: 32))
    }

    func testBottomSitsInsideTheBottomOfAFullScreenWindow() {
        let p = place(.bottom, screen, fullScreen: true)
        XCTAssertEqual(p.dock, .inside)
        XCTAssertEqual(p.frame, NSRect(x: 4, y: 3, width: 1702, height: 32))
        XCTAssertNil(p.lipFrame, "no lip at the bottom")
    }
}
