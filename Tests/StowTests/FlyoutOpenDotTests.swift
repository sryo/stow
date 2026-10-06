import XCTest
@testable import StowCore

/// A flyout row marks an open tab the way the list and rail do: a 4pt ink dot just left
/// of the glyph, not a green dot on the trailing side.
@MainActor
final class FlyoutOpenDotTests: XCTestCase {
    func testTheOpenDotSitsJustLeftOfTheGlyph() {
        let glyph = NSRect(x: 6, y: 5, width: 16, height: 16)
        let dot = FlyoutListRowView.openDotRect(glyph: glyph)
        XCTAssertEqual(dot.size, NSSize(width: 4, height: 4))
        XCTAssertEqual(dot.maxX, glyph.minX - 1.5)
        XCTAssertEqual(dot.midY, glyph.midY)
    }

    func testTheOpenDotIsInkNotGreen() {
        XCTAssertEqual(FlyoutListRowView.openDotColor, FlyoutColors.ink.withAlphaComponent(0.9))
    }
}
