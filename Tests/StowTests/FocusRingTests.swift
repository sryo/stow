import XCTest
@testable import StowCore

/// A focus ring shows only once the keyboard is in use (Tab, or a key pressed on the
/// focused control), like CSS :focus-visible. Opening Settings or the app sheet shows none.
@MainActor
final class FocusRingTests: XCTestCase {
    private var savedPolicy: (() -> Bool)!

    override func setUp() async throws {
        savedPolicy = FocusRing.focusCameFromKeyboard
    }

    override func tearDown() async throws {
        FocusRing.focusCameFromKeyboard = savedPolicy
    }

    private final class Probe: FocusableControl {}

    private func window(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = window.contentView!.bounds
        window.contentView?.addSubview(view)
        return window
    }

    func testFocusThatDidNotComeFromTheKeyboardDrawsNoRing() {
        FocusRing.focusCameFromKeyboard = { false }
        let probe = Probe(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let window = window(with: probe)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(probe))
        XCTAssertTrue(probe.hasFocus)
        XCTAssertFalse(probe.isFocused, "no ring until the keyboard is used")
        probe.keyDown(with: keyEvent(125))
        XCTAssertTrue(probe.isFocused, "a key on the focused control brings the ring")
        window.makeFirstResponder(nil)
        XCTAssertFalse(probe.isFocused)
        XCTAssertFalse(probe.hasFocus)
    }

    func testTabbingInDrawsTheRing() {
        FocusRing.focusCameFromKeyboard = { true }
        let probe = Probe(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let window = window(with: probe)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(probe))
        XCTAssertTrue(probe.isFocused)
    }

    func testThePlacementPickersFollowTheSameRule() {
        FocusRing.focusCameFromKeyboard = { false }
        let picker = WindowPlacementPicker()
        picker.placement = WindowPlacement(dock: .left, keepsOnTop: false, lastEdge: .left)
        picker.frame = NSRect(x: 0, y: 0, width: 252, height: picker.height(forWidth: 252))
        let window = window(with: picker)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(picker))
        XCTAssertFalse(picker.showsFocusRing)
        XCTAssertTrue(window.makeFirstResponder(picker.edgePicker))
        XCTAssertFalse(picker.edgePicker.showsFocusRing, "the edge shows no ring on open")
        FocusRing.focusCameFromKeyboard = { true }
        XCTAssertTrue(window.makeFirstResponder(picker))
        XCTAssertTrue(picker.showsFocusRing)
        XCTAssertTrue(window.makeFirstResponder(picker.edgePicker))
        XCTAssertTrue(picker.edgePicker.showsFocusRing)
    }

    func testOpeningTheSettingsPageShowsNoRing() {
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
        harness.spin(0.1)
        XCTAssertTrue(ringedViews(in: window.contentView!).isEmpty,
                      "rings on open: \(ringedViews(in: window.contentView!))")
    }

    func testOpeningTheAppSheetShowsNoRing() {
        let sheet = AppSheetView(style: .flyout)
        sheet.frame = NSRect(x: 0, y: 0, width: AppSheetView.width, height: sheet.preferredHeight(forWidth: AppSheetView.width))
        let panel = NSPanel(contentRect: sheet.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }
        panel.contentView?.addSubview(sheet)
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(ringedViews(in: panel.contentView!).isEmpty, "rings on open: \(ringedViews(in: panel.contentView!))")
    }

    func testAWindowOpenedByAClickGivesNoControlFocusSoTheFirstTabLandsOnThePicker() {
        let savedEvent = FocusRing.currentEvent
        defer { FocusRing.currentEvent = savedEvent }
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        FocusRing.currentEvent = { click }
        let sheet = AppSheetView(style: .flyout)
        sheet.frame = NSRect(x: 0, y: 0, width: AppSheetView.width, height: sheet.preferredHeight(forWidth: AppSheetView.width))
        let panel = NSPanel(contentRect: sheet.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }
        panel.contentView?.addSubview(sheet)
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(panel.firstResponder is WindowPlacementPicker, "opening the sheet doesn't put focus on the cards")
        XCTAssertFalse(panel.firstResponder is FocusableControl)

        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        FocusRing.currentEvent = { tab }
        panel.recalculateKeyViewLoop()
        panel.selectNextKeyView(nil)
        XCTAssertTrue(panel.firstResponder === sheet.placementPicker, "the first Tab lands on the cards")
        XCTAssertTrue(sheet.placementPicker.showsFocusRing)
    }

    private func ringedViews(in root: NSView) -> [String] {
        var found: [String] = []
        if let control = root as? FocusableControl, control.isFocused { found.append("\(type(of: control))") }
        if let picker = root as? WindowPlacementPicker, picker.showsFocusRing { found.append("WindowPlacementPicker") }
        if let picker = root as? BrowserDockPicker, picker.showsFocusRing { found.append("BrowserDockPicker") }
        for view in root.subviews { found += ringedViews(in: view) }
        return found
    }

    private func keyEvent(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
    }
}
