import XCTest
@testable import StowShared

/// Mid-swipe, the chrome on the page (search field, footer buttons) takes the same blend
/// of the two workspaces' palettes as the background, instead of keeping the old one.
final class PaletteBlendTests: XCTestCase {
    private let from = StowTheme.colors(for: .ocean)
    private let to = StowTheme.colors(for: .ruby)

    func testEndsAreTheTwoPalettes() {
        XCTAssertEqual(from.blended(with: to, fraction: 0).light, from.light)
        XCTAssertEqual(from.blended(with: to, fraction: 1).dark, to.dark)
    }

    func testHalfwayMixesEveryToken() {
        let mid = from.blended(with: to, fraction: 0.5)
        XCTAssertEqual(mid.light.hover, from.light.hover.mix(to.light.hover, 0.5))
        XCTAssertEqual(mid.dark.inkPrimary, from.dark.inkPrimary.mix(to.dark.inkPrimary, 0.5))
        XCTAssertEqual(mid.light.surface, from.light.surface.mix(to.light.surface, 0.5))
    }

    func testFractionIsClamped() {
        XCTAssertEqual(from.blended(with: to, fraction: -1).light, from.light)
        XCTAssertEqual(from.blended(with: to, fraction: 2).light, to.light)
    }
}
