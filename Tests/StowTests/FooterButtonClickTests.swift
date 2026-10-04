import AppKit
import XCTest
@testable import StowCore

/// A click on a footer button's label or icon must press the button. The label is an
/// NSTextField, which took the click, so "+ Stow this tab" never fired from a click.
@MainActor
final class FooterButtonClickTests: XCTestCase {
    func testClicksOnTheLabelHitTheButton() {
        let button = FooterButton(title: "+ Stow this tab", keycap: "⌥⌘S", symbolName: "plus")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        host.addSubview(button)
        button.frame = NSRect(x: 10, y: 4, width: 160, height: 30)
        button.layoutSubtreeIfNeeded()
        for x in stride(from: 20, through: 160, by: 20) {
            let hit = host.hitTest(NSPoint(x: CGFloat(x), y: 19))
            XCTAssertTrue(hit === button, "a click at x=\(x) went to \(String(describing: hit.map { type(of: $0) }))")
        }
    }

    /// "Stow this tab" is clicked from the browser, while Stow is in the background. The
    /// first click must press it, not just bring the window forward.
    func testActsOnTheFirstClickWhileStowIsInTheBackground() {
        let button = FooterButton(title: "+ Stow this tab", keycap: "⌥⌘S", symbolName: "plus")
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
    }
}
