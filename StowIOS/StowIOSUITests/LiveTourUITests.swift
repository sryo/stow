import XCTest

/// End-to-end walks through every surface the Settings plan touches: the Settings sheet,
/// page color on the page, the share extension from Safari, widget configuration and the
/// Live Activity. Each step saves a screenshot when STOW_TOUR_DIR is set (pass it as
/// TEST_RUNNER_STOW_TOUR_DIR to xcodebuild); without it the tour is skipped.
final class LiveTourUITests: XCTestCase {
    private var tourDir: URL!

    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/iOSSeed/settings-workspaces.json").path
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["STOW_TOUR_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_STOW_TOUR_DIR to run the live tour")
        }
        tourDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: tourDir, withIntermediateDirectories: true)
    }

    private func snap(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: tourDir.appendingPathComponent("\(name).png"))
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.debugDescription.write(to: tourDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    private func launchStow(seed: Bool, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if seed { app.launchEnvironment["STOW_SEED_FIXTURE_JSON"] = try! String(contentsOfFile: fixturePath, encoding: .utf8) }
        if reset { app.launchEnvironment["STOW_RESET_SETTINGS"] = "1" }
        app.launch()
        return app
    }

    /// Drags the sheet from its medium detent to large.
    private func expandSheet(_ app: XCUIApplication) {
        let bar = app.navigationBars["Settings"]
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
        start.press(forDuration: 0.1, thenDragTo: end)
        sleep(1)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Workspaces"].firstMatch.tap()
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        sleep(1)
    }

    private func closeSettings(_ app: XCUIApplication) {
        app.navigationBars["Settings"].buttons["Done"].tap()
        sleep(1)
        if app.navigationBars["Workspaces"].exists {
            app.navigationBars["Workspaces"].buttons["Done"].tap()
            sleep(1)
        }
    }

    // MARK: Settings and page color

    func testTour1SettingsAndPageColor() {
        let app = launchStow(seed: true, reset: true)
        sleep(1)
        snap("01-page-full")
        openSettings(app)
        snap("02-settings-medium")
        dump(app, "02-settings-medium")
        expandSheet(app)
        sleep(1)
        snap("03-settings-large")
        dump(app, "03-settings-large")

        app.buttons["Neutral"].tap()
        sleep(1)
        snap("04-settings-neutral")
        closeSettings(app)
        snap("05-page-neutral")

        openSettings(app)
        app.buttons["Color"].tap()
        XCTAssertTrue(app.buttons["Color"].isSelected)
        closeSettings(app)
    }

    // MARK: Live Activity

    func testTour2LiveActivityShowsTheChosenWorkspace() {
        let app = launchStow(seed: true, reset: true)
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        snap("10-island-open-workspace")

        app.activate()
        openSettings(app)
        app.buttons["settings.shows"].tap()
        XCTAssertTrue(app.navigationBars["Shows"].waitForExistence(timeout: 5))
        app.collectionViews.buttons["Home"].firstMatch.tap()
        sleep(1)
        snap("11-settings-shows-home")
        closeSettings(app)
        XCUIDevice.shared.press(.home)
        sleep(2)
        snap("12-island-pinned-home")
    }

    // MARK: Share extension

    func testTour3ShareFromSafari() throws {
        let stow = launchStow(seed: true, reset: true)
        sleep(1)
        XCUIDevice.shared.press(.home)   // leave it running in the background

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://www.apple.com/swift/")!)
        sleep(4)
        snap("20-safari")
        safari.buttons["MoreMenuButton"].tap()
        sleep(2)
        snap("21-safari-menu")
        dump(safari, "21-safari-menu")
        let share = safari.buttons.matching(NSPredicate(format: "label IN %@", ["Compartir", "Share"])).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        sleep(3)
        snap("22-share-sheet")
        safari.cells["Stow"].firstMatch.tap()
        sleep(3)
        snap("23-stow-share-default")
        dump(safari, "23-stow-share-default")

        // The last opened workspace (Work) is preselected; pick Reading instead.
        let work = safari.buttons["Work"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        XCTAssertTrue(work.isSelected)
        safari.buttons["Reading"].firstMatch.tap()
        XCTAssertTrue(safari.buttons["Reading"].firstMatch.isSelected)
        XCTAssertFalse(safari.buttons["Work"].firstMatch.isSelected)
        sleep(2)
        snap("24-stow-share-reading")
        let title = safari.staticTexts["share.title"].label
        safari.navigationBars["Stow"].buttons["Save"].tap()
        sleep(3)

        // The running app picks the link up and shows it in Reading.
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.buttons["Workspaces"].firstMatch.tap()
        let reading = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Reading'")).firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        reading.tap()
        sleep(2)
        snap("25-reading-has-link")
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "missing \(title)")
    }

    // MARK: Widget

    /// Leaves the home screen as it found it, so reruns don't pile up widgets.
    private func removeStowWidgets(_ springboard: XCUIApplication) {
        for _ in 0..<8 {
            let widget = springboard.otherElements.matching(NSPredicate(format: "label == 'Stow'")).firstMatch
            guard widget.exists, widget.frame.height > 100 else { return }
            widget.press(forDuration: 1.5)
            let remove = springboard.buttons["com.apple.springboardhome.application-shortcut-item.remove-widget"]
            guard remove.waitForExistence(timeout: 3) else { return }
            remove.tap()
            let confirm = springboard.alerts.buttons.element(boundBy: 1)
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            sleep(2)
        }
    }

    func testTour4WidgetConfiguration() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        sleep(1)
        removeStowWidgets(springboard)
        snap("30-home")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 2.0)
        sleep(2)
        snap("31-edit-mode")
        springboard.buttons["Editar"].firstMatch.tap()
        sleep(2)
        dump(springboard, "32-edit-menu")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'widget'")).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        addWidget.tap()
        sleep(3)
        snap("33-gallery")
        let search = springboard.searchFields.firstMatch
        search.tap()
        search.typeText("Stow")
        sleep(2)
        springboard.cells.matching(NSPredicate(format: "label CONTAINS 'Stow'")).firstMatch.tap()
        sleep(3)
        snap("34-stow-widget-gallery")
        springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Agregar widget' OR label CONTAINS 'Add Widget'")).firstMatch.tap()
        sleep(3)
        springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Listo", "Done"])).firstMatch.tap()
        sleep(2)
        snap("35-widget-current")
        dump(springboard, "35-widget-current")
        let widget = springboard.otherElements.matching(NSPredicate(format: "label CONTAINS 'Quick Links' OR label BEGINSWITH 'Stow'")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5))
        widget.press(forDuration: 1.5)
        sleep(2)
        snap("36-widget-menu")
        springboard.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"].tap()
        sleep(8)
        snap("37-edit-widget")
        dump(springboard, "37-edit-widget")
        XCTAssertTrue(springboard.buttons["Current workspace"].exists)
        springboard.buttons["Current workspace"].tap()
        sleep(3)
        snap("38-workspace-list")
        dump(springboard, "38-workspace-list")
        let home = springboard.buttons["Home"].exists ? springboard.buttons["Home"] : springboard.cells["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        sleep(2)
        snap("39-edit-widget-home")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        sleep(4)
        snap("40-widget-home")
        dump(springboard, "40-widget-home")
        XCTAssertTrue(springboard.staticTexts["Home"].exists)
        XCTAssertTrue(springboard.buttons["Recipes"].exists)
    }
}
