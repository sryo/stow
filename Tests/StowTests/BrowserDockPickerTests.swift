import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class StubLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

/// The "With your browser" picker and the app sheet rows around it.
@MainActor
final class BrowserDockPickerTests: XCTestCase {
    private var accessibility = true
    private var requests = 0

    private func makePreferences() -> AppPreferences {
        AppPreferences(defaults: scratchDefaults(), loginItem: StubLoginItem(),
                       hasAccessibility: { [unowned self] in self.accessibility }, applyTabline: { _ in },
                       requestAccessibility: { [unowned self] in self.requests += 1 })
    }

    // MARK: The picker on its own

    func testEdgeZonesCoverTheFourSidesOfTheDrawing() {
        let window = NSRect(x: 0, y: 0, width: 200, height: 120)
        typealias P = BrowserDockPicker
        XCTAssertEqual(P.edge(at: NSPoint(x: 8, y: 60), window: window), .left)
        XCTAssertEqual(P.edge(at: NSPoint(x: 192, y: 60), window: window), .right)
        // Flipped: y grows downward, so the top strip is near y = 0.
        XCTAssertEqual(P.edge(at: NSPoint(x: 100, y: 6), window: window), .top)
        XCTAssertEqual(P.edge(at: NSPoint(x: 100, y: 114), window: window), .bottom)
        XCTAssertNil(P.edge(at: NSPoint(x: 100, y: 60), window: window), "the middle isn't an edge")
        XCTAssertNil(P.edge(at: NSPoint(x: 300, y: 60), window: window))
    }

    func testClickingAnEdgeChoosesItAndClickingItAgainDetaches() {
        let picker = BrowserDockPicker()
        var chosen: [BrowserDock] = []
        picker.onChange = { chosen.append($0) }
        picker.choose(.left)
        XCTAssertEqual(chosen, [.left])
        picker.dock = .left
        picker.choose(.left)
        XCTAssertEqual(chosen, [.left, .none], "the selected edge again means Not attached")
    }

    func testArrowKeysMoveBetweenEdgesAndSpaceSelects() {
        let picker = BrowserDockPicker()
        var chosen: [BrowserDock] = []
        picker.onChange = { chosen.append($0) }
        XCTAssertTrue(picker.acceptsFirstResponder)
        picker.handleKey(.up)
        XCTAssertEqual(picker.focusedEdge, .top)
        XCTAssertEqual(chosen, [], "moving focus doesn't choose")
        picker.handleKey(.right)
        XCTAssertEqual(picker.focusedEdge, .right)
        picker.handleKey(.select)
        XCTAssertEqual(chosen, [.right])
        picker.dock = .right
        picker.handleKey(.down)
        picker.handleKey(.select)
        XCTAssertEqual(chosen, [.right, .bottom])
    }

    func testVoiceOverSeesFourRadioButtonsAndTheSelection() {
        let picker = BrowserDockPicker()
        picker.dock = .top
        let edges = picker.accessibilityChildren() as? [NSAccessibilityElement] ?? []
        XCTAssertEqual(edges.map { $0.accessibilityLabel() ?? "" },
                       ["Sidebar on the left", "Sidebar on the right", "Tabline on top", "Tabline at the bottom"])
        XCTAssertTrue(edges.allSatisfy { $0.accessibilityRole() == .radioButton })
        XCTAssertEqual(edges.map { ($0.accessibilityValue() as? Bool) ?? false }, [false, false, true, false])
        XCTAssertEqual(picker.accessibilityLabel(), "With your browser")
    }

    // MARK: In the app sheet

    func testSheetCaptionAndRowsFollowTheDock() {
        let preferences = makePreferences()
        let sheet = AppSheetView(style: .page, preferences: preferences)
        sheet.frame.size.width = 320
        XCTAssertEqual(sheet.dockPicker.dock, .none)
        XCTAssertEqual(sheet.visibleWindowRows, [.dock, .keepOnTop, .openAtLogin])
        XCTAssertEqual(sheet.dockCaption, AppSheet.dockCaption(.none))

        preferences.setDock(.right)
        sheet.refresh()
        XCTAssertEqual(sheet.dockPicker.dock, .right)
        XCTAssertEqual(sheet.dockCaption, "Sidebar on the right of your browser")
        XCTAssertEqual(sheet.visibleWindowRows, [.dock, .openAtLogin])

        sheet.dockPicker.choose(.top)
        XCTAssertEqual(preferences.dock, .top, "the picker goes through AppPreferences")
        sheet.refresh()
        XCTAssertEqual(sheet.dockCaption, "Tabs ride above your browser · ⌥⌘L")
        XCTAssertEqual(sheet.visibleWindowRows, [.dock, .keepOnTop, .openAtLogin])
    }

    func testChoosingAnEdgeInTheSheetWithoutAccessibilityAsksAndShowsTheWarning() {
        accessibility = false
        let preferences = makePreferences()
        let sheet = AppSheetView(style: .page, preferences: preferences)
        XCTAssertEqual(sheet.permissionReasons, [])
        sheet.dockPicker.choose(.bottom)
        XCTAssertEqual(requests, 1)
        sheet.refresh()
        XCTAssertEqual(sheet.permissionReasons, ["The Tabline needs Accessibility"])
    }
}
