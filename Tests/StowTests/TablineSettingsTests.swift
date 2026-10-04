import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class StubLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

/// The Tabline's gear: the same app sheet as the rail's, in a flyout that opens away
/// from the edge the strip rides; and the chip's way into the workspace editor.
@MainActor
final class TablineSettingsTests: XCTestCase {
    private var parent: NSPanel!

    override func setUp() async throws {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        parent = NSPanel(contentRect: NSRect(x: screen.midX - 500, y: screen.midY - 16, width: 1000, height: 32),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    override func tearDown() async throws {
        parent.orderOut(nil)
        parent = nil
    }

    private func makeFlyout() -> AppSheetFlyout {
        let preferences = AppPreferences(defaults: scratchDefaults(), loginItem: StubLoginItem(),
                                         hasAccessibility: { true }, applyTabline: { _ in }, requestAccessibility: {})
        return AppSheetFlyout(preferences: preferences)
    }

    private var gearAnchor: NSRect { NSRect(x: parent.frame.minX + 5, y: parent.frame.minY + 4, width: 24, height: 24) }

    func testFlyoutEdgeFollowsTheTablineEdge() {
        XCTAssertEqual(TablineController.flyoutEdge(for: .top), .below)
        XCTAssertEqual(TablineController.flyoutEdge(for: .bottom), .above)
    }

    func testGearOpensTheAppSheetBelowTheStripOnTheTopEdge() {
        let flyout = makeFlyout()
        flyout.toggle(anchor: gearAnchor, edge: .top, parent: parent)
        XCTAssertTrue(flyout.isOpen)
        XCTAssertTrue(flyout.sheetPanel.content === flyout.sheet, "the panel hosts the shared AppSheetView")
        XCTAssertEqual(flyout.sheet.style, .flyout)
        XCTAssertEqual(flyout.sheetPanel.frame.width, AppSheetView.width)
        XCTAssertLessThanOrEqual(flyout.sheetPanel.frame.maxY, gearAnchor.minY, "below the gear")
        XCTAssertTrue(parent.childWindows?.contains(flyout.sheetPanel) == true, "rides the Tabline panel")
        XCTAssertTrue(flyout.sheetPanel.canBecomeKey, "the shortcut recorders need the keyboard")
        flyout.toggle(anchor: gearAnchor, edge: .top, parent: parent)
        XCTAssertFalse(flyout.isOpen, "the gear again closes it")
    }

    func testGearOpensTheAppSheetAboveTheStripOnTheBottomEdge() {
        let flyout = makeFlyout()
        flyout.toggle(anchor: gearAnchor, edge: .bottom, parent: parent)
        XCTAssertTrue(flyout.isOpen)
        XCTAssertGreaterThanOrEqual(flyout.sheetPanel.frame.minY, gearAnchor.maxY, "above the gear")
        flyout.close()
        XCTAssertFalse(flyout.isOpen)
    }

    func testSheetTakesTheWorkspaceColorAndPushesAllShortcuts() {
        let flyout = makeFlyout()
        flyout.toggle(anchor: gearAnchor, edge: .top, parent: parent, colorId: .ocean)
        XCTAssertEqual(flyout.sheet.previewColor, .ocean)
        flyout.sheet.onShowAllShortcuts?(flyout.sheet.toggleRecorder)
        XCTAssertEqual(flyout.flyouts.openIds.count, 2, "All shortcuts is pushed beside the sheet")
        flyout.close()
        XCTAssertFalse(flyout.flyouts.isOpen)
    }

    func testSheetImportGoesThroughTheAppsImport() {
        let flyout = makeFlyout()
        let posted = expectation(forNotification: .stowShowImport, object: nil)
        flyout.toggle(anchor: gearAnchor, edge: .top, parent: parent)
        flyout.sheet.onImport?()
        wait(for: [posted], timeout: 1)
        XCTAssertFalse(flyout.isOpen, "Import closes the sheet")
    }

    func testChipListOffersEditWorkspace() {
        var edited = false
        let footer = TablineController.chipFooter { edited = true }
        XCTAssertEqual(footer.map(\.title), ["Edit Workspace…"])
        footer.first?.action()
        XCTAssertTrue(edited)
    }

    /// With `TABLINE_RENDER_DIR` set, writes the sheet flyout (card and arrow) for both
    /// edges in light and dark.
    func testRenderSheetFlyout() throws {
        guard let dir = ProcessInfo.processInfo.environment["TABLINE_RENDER_DIR"] else { throw XCTSkip("TABLINE_RENDER_DIR not set") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for edge in [TablineEdge.top, .bottom] {
                let flyout = makeFlyout()
                flyout.sheetPanel.appearance = NSAppearance(named: appearance)
                flyout.toggle(anchor: gearAnchor, edge: edge, parent: parent, colorId: .ocean)
                let view = try XCTUnwrap(flyout.sheetPanel.contentView)
                view.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("sheet_\(edge.rawValue)_\(name).png"))
                flyout.close()
            }
        }
    }

    func testFlyoutPlacementAboveSitsOverTheAnchor() {
        let screen = NSRect(x: 0, y: 0, width: 1710, height: 1075)
        let anchor = NSRect(x: 100, y: 3, width: 24, height: 24)
        let above = FlyoutPlacement.above(width: 276, anchor: anchor, screen: screen)
        XCTAssertEqual(above.minY, anchor.maxY + FlyoutPlacement.gap)
        XCTAssertEqual(above.minX, FlyoutPlacement.gap, "clamped to the screen's left side")
        XCTAssertEqual(above.arrowFromLeft, anchor.midX - FlyoutPlacement.gap)
    }
}
