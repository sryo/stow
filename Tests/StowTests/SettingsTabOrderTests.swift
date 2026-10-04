import AppKit
import XCTest
@testable import StowCore

/// Tab walks through the Settings page: from the placement cards on to the controls
/// below, instead of staying stuck on the first one.
@MainActor
final class SettingsTabOrderTests: XCTestCase {
    private func pressTab(in window: NSWindow) {
        window.selectNextKeyView(nil)
    }

    func testTabMovesFromThePlacementCardsToTheNextControls() throws {
        let harness = RedHarness()
        defer { harness.tearDown() }
        let settings = SettingsContentViewController()
        settings.appModel = harness.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentViewController = settings
        window.makeKeyAndOrderFront(nil)
        harness.spin(0.2)

        let first = settings.sheet.placementPicker
        let saved = FocusRing.currentEvent
        defer { FocusRing.currentEvent = saved }
        FocusRing.currentEvent = { nil }
        window.recalculateKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(first))

        var visited: [ObjectIdentifier] = [ObjectIdentifier(first)]
        for _ in 0..<3 {
            pressTab(in: window)
            harness.spin(0.15)
            if let responder = window.firstResponder { visited.append(ObjectIdentifier(responder)) }
        }
        XCTAssertFalse(window.firstResponder === first, "Tab stayed on the placement cards")
        XCTAssertGreaterThan(Set(visited).count, 2, "Tab didn't move past the cards")
    }
}
