import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class StubLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

/// The small browser drawing that opens under Attached: four clickable edges, left and
/// right for the sidebar, top and bottom for the Tabline.
@MainActor
final class BrowserDockPickerTests: XCTestCase {
    private var accessibility = true
    private var requests = 0

    private func makePreferences() -> AppPreferences {
        AppPreferences(defaults: scratchDefaults(), loginItem: StubLoginItem(),
                       hasAccessibility: { [unowned self] in self.accessibility }, applyTabline: { _ in },
                       requestAccessibility: { [unowned self] in self.requests += 1 })
    }

    // MARK: Geometry

    func testZonesMatchTheDesignInTheSheet() {
        // .eb 96×66: .ez.l 4,15 13×36 · .ez.r right 4 · .ez.t 20,3 56×9 · .ez.b bottom 3.
        let zones = BrowserDockPicker.zones(compact: true)
        XCTAssertEqual(zones[.left], NSRect(x: 4, y: 15, width: 13, height: 36))
        XCTAssertEqual(zones[.right], NSRect(x: 79, y: 15, width: 13, height: 36))
        XCTAssertEqual(zones[.top], NSRect(x: 20, y: 3, width: 56, height: 9))
        XCTAssertEqual(zones[.bottom], NSRect(x: 20, y: 54, width: 56, height: 9))
        XCTAssertEqual(BrowserDockPicker.windowRect(compact: true), NSRect(x: 20, y: 15, width: 56, height: 36))
        XCTAssertEqual(BrowserDockPicker.drawingSize(compact: true), NSSize(width: 96, height: 66))
    }

    func testZonesMatchTheDesignOnThePage() {
        // .page .eb 104×70: l 5,16 13×38 · r right 5 · t 22,3 60×10 · b bottom 3.
        let zones = BrowserDockPicker.zones(compact: false)
        XCTAssertEqual(zones[.left], NSRect(x: 5, y: 16, width: 13, height: 38))
        XCTAssertEqual(zones[.right], NSRect(x: 86, y: 16, width: 13, height: 38))
        XCTAssertEqual(zones[.top], NSRect(x: 22, y: 3, width: 60, height: 10))
        XCTAssertEqual(zones[.bottom], NSRect(x: 22, y: 57, width: 60, height: 10))
        XCTAssertEqual(BrowserDockPicker.windowRect(compact: false), NSRect(x: 22, y: 16, width: 60, height: 38))
    }

    func testHitTestingFindsEachEdge() {
        typealias P = BrowserDockPicker
        XCTAssertEqual(P.edge(at: NSPoint(x: 10, y: 33), compact: true), .left)
        XCTAssertEqual(P.edge(at: NSPoint(x: 85, y: 33), compact: true), .right)
        XCTAssertEqual(P.edge(at: NSPoint(x: 48, y: 7), compact: true), .top)
        XCTAssertEqual(P.edge(at: NSPoint(x: 48, y: 58), compact: true), .bottom)
        XCTAssertEqual(P.edge(at: NSPoint(x: 48, y: 1), compact: true), .top, "a little slack around the thin strips")
        XCTAssertEqual(P.edge(at: NSPoint(x: 2, y: 33), compact: true), .left)
        XCTAssertNil(P.edge(at: NSPoint(x: 48, y: 33), compact: true), "the middle of the window isn't an edge")
        XCTAssertNil(P.edge(at: NSPoint(x: 200, y: 33), compact: true))
        XCTAssertEqual(P.edge(at: NSPoint(x: 80, y: 62), compact: false), .bottom)
    }

    // MARK: Choosing

    func testClickingAnEdgeChoosesItAndAgainKeepsIt() {
        let picker = BrowserDockPicker()
        var chosen: [BrowserDock] = []
        picker.onChange = { chosen.append($0) }
        picker.choose(.left)
        XCTAssertEqual(chosen, [.left])
        picker.dock = .left
        picker.choose(.left)
        XCTAssertEqual(chosen, [.left, .left], "the selected edge stays chosen; the cards detach")
    }

    func testArrowKeysChooseTheEdgeTheyPointAt() {
        let picker = BrowserDockPicker()
        picker.dock = .left
        var chosen: [BrowserDock] = []
        picker.onChange = { chosen.append($0) }
        picker.handleKey(.up)
        XCTAssertEqual(picker.focusedEdge, .top)
        picker.handleKey(.right)
        picker.handleKey(.down)
        picker.handleKey(.left)
        XCTAssertEqual(chosen, [.top, .right, .bottom, .left], "↑ top, → right, ↓ bottom, ← left, like a radio group")
    }

    func testSpaceAndReturnChooseTheFocusedEdge() {
        let picker = BrowserDockPicker()
        picker.dock = .right
        var chosen: [BrowserDock] = []
        picker.onChange = { chosen.append($0) }
        XCTAssertTrue(picker.acceptsFirstResponder || NSApp.currentEvent?.type == .leftMouseDown)
        XCTAssertTrue(picker.becomeFirstResponder())
        XCTAssertEqual(picker.focusedEdge, .right, "focus starts on the chosen edge")
        picker.handleKey(.select)
        XCTAssertEqual(chosen, [.right])
        picker.keyDown(with: keyEvent(36))
        picker.keyDown(with: keyEvent(49))
        XCTAssertEqual(chosen, [.right, .right, .right])
        picker.keyDown(with: keyEvent(126))
        XCTAssertEqual(chosen.last, .top, "↑ through keyDown")
    }

    func testVoiceOverSeesFourRadioButtons() {
        let picker = BrowserDockPicker()
        picker.dock = .top
        let edges = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(edges.map { $0.accessibilityLabel() ?? "" },
                       ["Tabline on top", "Sidebar on the left", "Sidebar on the right", "Tabline at the bottom"])
        XCTAssertTrue(edges.allSatisfy { $0.accessibilityRole() == .radioButton })
        XCTAssertEqual(edges.map { ($0.accessibilityValue() as? Bool) ?? false }, [true, false, false, false])
        XCTAssertEqual(picker.accessibilityRole(), .radioGroup)
        XCTAssertEqual(picker.accessibilityLabel(), "Edge of the browser window")
        XCTAssertTrue(edges[2].accessibilityPerformPress())
    }

    // MARK: Caption

    func testCaptionNamesTheChosenEdgeAndPreviewsTheHoveredOne() {
        let picker = BrowserDockPicker()
        picker.dock = .left
        XCTAssertEqual(picker.caption.title, "Sidebar on the left")
        XCTAssertEqual(picker.caption.detail, "Docks to the browser’s left side.")
        XCTAssertEqual(picker.caption.hint, "Click the top or bottom edge for the Tabline.")
        picker.hoveredEdge = .bottom
        XCTAssertEqual(picker.caption.title, "Tabline at the bottom", "hovering previews before you click")
        XCTAssertEqual(picker.caption.hint, "Tabline only rides the top or bottom edge.")
        picker.hoveredEdge = nil
        XCTAssertEqual(picker.caption.title, "Sidebar on the left")
    }

    func testHeightFitsTheCaption() {
        let picker = BrowserDockPicker()
        picker.dock = .left
        // .edge: 8 + max(66, caption) + 8. In the sheet the caption wraps to 75pt.
        XCTAssertEqual(picker.height(forWidth: 252, compact: true), 91, accuracy: 2)
        XCTAssertEqual(picker.height(forWidth: 308, compact: false), 86, accuracy: 2, "the page fits the detail on one line")
    }

    // MARK: In the app sheet

    func testSheetShowsThePlacementAndGoesThroughAppPreferences() {
        let preferences = makePreferences()
        let sheet = AppSheetView(style: .page, preferences: preferences)
        sheet.frame.size.width = 320
        XCTAssertEqual(sheet.placementPicker.placement.mode, .floating)
        XCTAssertEqual(sheet.visibleWindowRows, [.placement, .openAtLogin])
        XCTAssertFalse(sheet.placementPicker.isEdgePickerVisible)

        preferences.setDock(.right)
        sheet.refresh()
        XCTAssertEqual(sheet.placementPicker.placement, WindowPlacement(dock: .right, keepsOnTop: false, lastEdge: .right))
        XCTAssertTrue(sheet.placementPicker.isEdgePickerVisible)

        sheet.placementPicker.edgePicker.choose(.top)
        XCTAssertEqual(preferences.dock, .top, "the edge picker goes through AppPreferences")
        sheet.placementPicker.choose(.onTop)
        XCTAssertEqual(preferences.dock, .none)
        XCTAssertTrue(preferences.keepsOnTop, "the On top card is the old Keep on top switch")
        XCTAssertEqual(sheet.placementPicker.placement.mode, .onTop, "the sheet follows without waiting for a notification")
    }

    func testAttachingWithoutAccessibilityAsksAndShowsTheWarning() {
        accessibility = false
        let preferences = makePreferences()
        let sheet = AppSheetView(style: .flyout, preferences: preferences)
        XCTAssertFalse(sheet.placementPicker.isWarningVisible)
        sheet.placementPicker.choose(.attached)
        XCTAssertEqual(requests, 1, "starts the system permission flow")
        XCTAssertTrue(sheet.placementPicker.isWarningVisible)
        XCTAssertEqual(sheet.placementPicker.warningTitle, "Attached needs Accessibility.")
        sheet.placementPicker.edgePicker.choose(.bottom)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(sheet.placementPicker.warningTitle, "The Tabline needs Accessibility.")
        XCTAssertEqual(sheet.permissionReasons, [], "the warning sits under the edges, not in a second row")
    }

    func testAllowOpensAccessibilitySettings() {
        accessibility = false
        let preferences = makePreferences()
        let sheet = AppSheetView(style: .flyout, preferences: preferences)
        var allowed = 0
        sheet.onAllowAccessibility = { allowed += 1 }
        sheet.placementPicker.choose(.attached)
        sheet.placementPicker.allow()
        XCTAssertEqual(allowed, 1)
    }

    private func keyEvent(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
    }
}
