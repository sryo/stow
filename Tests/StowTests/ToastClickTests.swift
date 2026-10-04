import AppKit
import XCTest
@testable import StowCore

/// Clicks the toast's Undo through the window server, the way a person does. It moves
/// the real pointer, so it only runs when asked: `STOW_UI_CLICKS=1 swift test --filter ToastClickTests`.
@MainActor
final class ToastClickTests: XCTestCase {
    /// Delivers queued events; `RunLoop.run` alone doesn't dispatch them in a test.
    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// `point` is in screen coordinates (origin bottom left).
    private func click(_ point: NSPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: point.x, y: height - point.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.15)
        // Down and up are both queued before the button's tracking loop runs.
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.4)
    }

    func testClickingUndoOnTheToastUndoes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_UI_CLICKS"] == "1", "moves the pointer; opt in")
        try XCTSkipUnless(AXIsProcessTrusted(), "posting clicks needs Accessibility permission")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu // above other apps' windows, so the click lands here
        window.makeKeyAndOrderFront(nil)
        defer { Toast.dismiss(expired: false); window.orderOut(nil) }
        pump(0.3)

        var undone = false
        Toast.show("Archived “Lisbon”", action: .undo { undone = true }, in: window)
        pump(0.3)
        let panel = try XCTUnwrap(window.childWindows?.first)
        let button = try XCTUnwrap(panel.contentView?.subviews.first { $0 is FlyoutButton })
        let saved = NSEvent.mouseLocation
        click(NSPoint(x: panel.convertToScreen(button.convert(button.bounds, to: nil)).midX,
                      y: panel.convertToScreen(button.convert(button.bounds, to: nil)).midY))
        CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: (NSScreen.screens.first?.frame.height ?? 0) - saved.y))
        XCTAssertTrue(undone)
        XCTAssertFalse(Toast.isShowing)
    }
}
