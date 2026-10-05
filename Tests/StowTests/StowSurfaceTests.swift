import XCTest
@testable import StowCore

/// Stow is on screen as one thing at a time: its window, or the Tabline on the browser.
/// Choosing the Tabline turns the window into it rather than adding a second one.
@MainActor
final class StowSurfaceTests: XCTestCase {
    private final class Screen {
        var windowShown = true
        var tablineHidden = false
    }

    private func make(_ screen: Screen) -> StowSurface {
        StowSurface(showWindow: { screen.windowShown = true },
                    hideWindow: { screen.windowShown = false },
                    setTablineHidden: { screen.tablineHidden = $0 })
    }

    func testTheTablineStartingPutsTheWindowAway() {
        let screen = Screen()
        let surface = make(screen)
        surface.tablineRunningChanged(true)
        XCTAssertFalse(screen.windowShown)
        surface.tablineRunningChanged(false)
        XCTAssertTrue(screen.windowShown, "back to a sidebar or floating, the window returns")
    }

    func testToggleStowHidesTheTablineNotTheWindowWhileItRuns() {
        let screen = Screen()
        let surface = make(screen)
        surface.tablineRunningChanged(true)
        surface.toggle()
        XCTAssertTrue(screen.tablineHidden)
        XCTAssertFalse(screen.windowShown)
        surface.toggle()
        XCTAssertFalse(screen.tablineHidden)
        XCTAssertFalse(screen.windowShown)
    }

    func testReopeningWhileTheTablineRunsShowsTheTablineOnly() {
        let screen = Screen()
        let surface = make(screen)
        surface.tablineRunningChanged(true)
        surface.toggle()
        surface.reopen()
        XCTAssertFalse(screen.tablineHidden)
        XCTAssertFalse(screen.windowShown)
    }

    func testLeavingTheTablineWhileItWasHiddenKeepsStowHidden() {
        let screen = Screen()
        let surface = make(screen)
        surface.tablineRunningChanged(true)
        surface.toggle()
        surface.tablineRunningChanged(false)
        XCTAssertFalse(screen.windowShown, "hidden stays hidden until Toggle Stow")
        XCTAssertFalse(screen.tablineHidden, "the next Tabline isn't born hidden")
        surface.toggle()
        XCTAssertTrue(screen.windowShown)
    }

    func testWithoutTheTablineToggleIsTheWindow() {
        let screen = Screen()
        let surface = make(screen)
        surface.toggle()
        XCTAssertFalse(screen.windowShown)
        XCTAssertTrue(surface.isUserHidden)
        surface.toggle()
        XCTAssertTrue(screen.windowShown)
        XCTAssertFalse(surface.isUserHidden)
    }
}
