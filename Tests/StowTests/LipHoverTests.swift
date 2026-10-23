import AppKit
import XCTest
@testable import StowCore

/// The full-screen lip: it peeks when the pointer heads for the top edge, not when it's
/// on its way down from the menu bar, and a brief trip off the strip doesn't fold it.
final class LipHoverTests: XCTestCase {

    private let lip = NSRect(x: 0, y: 1000, width: 1200, height: 5)
    private let peek = NSRect(x: 0, y: 960, width: 1200, height: 34)

    private func hover() -> LipHover { LipHover(lipFrame: lip, peekFrame: peek) }

    func testRestingInTheHotZonePeeks() {
        var h = hover()
        XCTAssertFalse(h.step(mouse: NSPoint(x: 600, y: 995), at: 0, peeking: false))
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 995), at: 0.06, peeking: false))
    }

    func testMovingUpIntoTheHotZonePeeks() {
        var h = hover()
        _ = h.step(mouse: NSPoint(x: 600, y: 900), at: 0, peeking: false)
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 995), at: 0.06, peeking: false))
    }

    func testComingDownFromTheMenuBarDoesNotPeek() {
        var h = hover()
        _ = h.step(mouse: NSPoint(x: 600, y: 1080), at: 0, peeking: false)
        XCTAssertFalse(h.step(mouse: NSPoint(x: 600, y: 1030), at: 0.06, peeking: false))
        XCTAssertFalse(h.step(mouse: NSPoint(x: 600, y: 985), at: 0.12, peeking: false))
    }

    func testABriefTripOffThePeekKeepsItOut() {
        var h = hover()
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 970), at: 0, peeking: true))
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 900), at: 0.06, peeking: true))
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 970), at: 0.12, peeking: true))
    }

    func testLeavingThePeekFoldsItAfterTheGrace() {
        var h = hover()
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 900), at: 0, peeking: true))
        XCTAssertTrue(h.step(mouse: NSPoint(x: 600, y: 900), at: 0.1, peeking: true))
        XCTAssertFalse(h.step(mouse: NSPoint(x: 600, y: 900), at: 0.2, peeking: true))
    }
}
