import XCTest
@testable import StowCore

/// Arc reports no focused or main window to Accessibility while its window is plainly in
/// front, so the Tabline falls back to the app's front-most window instead of hiding.
final class FrontWindowChoiceTests: XCTestCase {
    func testPrefersTheFocusedWindow() {
        XCTAssertEqual(FrontWindowChoice.pick(focused: "f", main: "m", windows: ["w1", "w2"]), "f")
    }

    func testFallsBackToTheMainWindow() {
        XCTAssertEqual(FrontWindowChoice.pick(focused: nil, main: "m", windows: ["w1"]), "m")
    }

    func testFallsBackToTheFrontMostWindowLikeArc() {
        XCTAssertEqual(FrontWindowChoice.pick(focused: nil, main: nil, windows: ["w1", "w2"]), "w1")
    }

    func testNoWindowsIsNil() {
        XCTAssertNil(FrontWindowChoice.pick(focused: String?.none, main: nil, windows: []))
    }
}
