import AppKit
import XCTest
@testable import StowCore

/// Tab walks through the Settings page: from the first workspace row to the next one and
/// on to the controls below, instead of staying stuck on the first row.
@MainActor
final class SettingsTabOrderTests: XCTestCase {
    private func rows(in view: NSView) -> [WorkspaceRowView] {
        var found: [WorkspaceRowView] = []
        func walk(_ v: NSView) { if let r = v as? WorkspaceRowView { found.append(r) }; v.subviews.forEach(walk) }
        walk(view)
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    private func pressTab(in window: NSWindow) {
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "\t",
                                   charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        window.sendEvent(tab)
    }

    func testTabMovesFromTheFirstWorkspaceRowToTheNextControls() throws {
        let harness = RedHarness()
        defer { harness.tearDown() }
        _ = harness.model.createWorkspace(name: "Second")
        let settings = SettingsContentViewController()
        settings.appModel = harness.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentViewController = settings
        window.makeKeyAndOrderFront(nil)
        harness.spin(0.2)

        let workspaceRows = rows(in: window.contentView!)
        XCTAssertGreaterThanOrEqual(workspaceRows.count, 2)
        let first = try XCTUnwrap(workspaceRows.first)
        let saved = FocusRing.currentEvent
        defer { FocusRing.currentEvent = saved }
        FocusRing.currentEvent = { nil }
        XCTAssertTrue(window.makeFirstResponder(first))

        var visited: [ObjectIdentifier] = [ObjectIdentifier(first)]
        for _ in 0..<3 {
            pressTab(in: window)
            harness.spin(0.15)
            if let responder = window.firstResponder { visited.append(ObjectIdentifier(responder)) }
        }
        XCTAssertFalse(window.firstResponder === first, "Tab stayed on the first workspace row")
        XCTAssertGreaterThan(Set(visited).count, 2, "Tab didn't move past the workspace rows")
    }
}
