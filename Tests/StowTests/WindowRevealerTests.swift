import XCTest
@testable import StowCore

/// Attached, the window comes back beside the browser without taking focus from it:
/// activating Stow there reads as "came from another app" and the attachment hides it.
@MainActor
final class WindowRevealerTests: XCTestCase {
    private func reveal(attached: Bool) -> [String] {
        var calls: [String] = []
        WindowRevealer(isAttached: { attached },
                       orderFront: { calls.append("front") },
                       makeKeyAndActivate: { calls.append("activate") },
                       placeOnBrowser: { calls.append("place") }).reveal()
        return calls
    }

    func testAttachedTheWindowReturnsBesideTheBrowserWithoutTakingFocus() {
        XCTAssertEqual(reveal(attached: true), ["place", "front"])
    }

    func testFloatingTheWindowComesForwardAndActive() {
        XCTAssertEqual(reveal(attached: false), ["activate"])
    }
}
