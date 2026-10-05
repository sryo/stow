import XCTest

/// Drives the real Settings sheet in the simulator: every control is changed and read back,
/// and choices survive a relaunch.
final class SettingsSheetUITests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/iOSSeed/settings-workspaces.json").path
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["STOW_SEED_FIXTURE_JSON"] = try! String(contentsOfFile: fixturePath, encoding: .utf8)
        if reset { app.launchEnvironment["STOW_RESET_SETTINGS"] = "1" }
        app.launch()
        return app
    }

    /// The Shows row reads as "Shows" plus its current value, wherever SwiftUI puts it.
    private func showsValue(_ app: XCUIApplication) -> String {
        let row = app.buttons["settings.shows"]
        let texts = row.staticTexts.allElementsBoundByIndex.map { $0.label }
        return ([row.label, row.value as? String ?? ""] + texts).joined(separator: " | ")
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
    }

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STOW_TOUR_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testShowsThePlannedRowsWithTheirDefaults() {
        let app = launch(reset: true)
        openSettings(app)

        XCTAssertTrue(app.staticTexts["iCloud"].exists)
        XCTAssertTrue(app.staticTexts["settings.icloud.status"].exists)
        // Fixture runs never sync, so the line reads Off rather than an iCloud state.
        XCTAssertEqual(app.staticTexts["settings.icloud.status"].label, "Off")
        XCTAssertTrue(app.staticTexts["ON THIS IPHONE"].exists || app.staticTexts["On this iPhone"].exists)
        XCTAssertTrue(app.staticTexts["EVERYWHERE"].exists || app.staticTexts["Everywhere"].exists)

        let island = app.switches["settings.island"]
        XCTAssertTrue(island.exists)
        XCTAssertEqual(island.value as? String, "1")

        XCTAssertTrue(showsValue(app).contains("Open workspace"), showsValue(app))
        XCTAssertTrue(app.buttons["Color"].isSelected)
        XCTAssertFalse(app.buttons["Neutral"].isSelected)
        XCTAssertFalse(app.buttons["Soft"].exists, "Soft is gone: page color is Color or Neutral")

        XCTAssertTrue(app.staticTexts["Sharing a link saves to the workspace you last opened. Pick another in the share sheet."].exists)

        // The sheet opens at the medium detent; pull it up to read the rest.
        sleep(1)
        expandSheet(app)
        snap("15-settings-page-color-two-segments")
        sleep(1)
        XCTAssertTrue(app.staticTexts["Syncs with Stow on your Mac."].waitForExistence(timeout: 3))

        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.links["Source on GitHub"].exists)
        XCTAssertTrue(app.staticTexts["Long-press a Stow widget to choose its workspace."].exists)
    }

    func testEveryControlChangesAndSurvivesARelaunch() {
        var app = launch(reset: true)
        openSettings(app)

        app.buttons["Neutral"].tap()
        XCTAssertTrue(app.buttons["Neutral"].isSelected)
        XCTAssertFalse(app.buttons["Color"].isSelected)

        app.buttons["settings.shows"].tap()
        XCTAssertTrue(app.navigationBars["Shows"].waitForExistence(timeout: 5))
        let work = app.collectionViews.buttons["Work"].firstMatch
        if !work.waitForExistence(timeout: 5) { print(app.debugDescription) }
        work.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(showsValue(app).contains("Work"), showsValue(app))

        let island = app.switches["settings.island"]
        island.switches.firstMatch.tap()
        XCTAssertEqual(island.value as? String, "0")
        XCTAssertFalse(app.buttons["settings.shows"].isEnabled)

        app.buttons["Color"].tap()
        XCTAssertTrue(app.buttons["Color"].isSelected)
        app.buttons["Neutral"].tap()
        XCTAssertTrue(app.buttons["Neutral"].isSelected)

        app.navigationBars["Settings"].buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 2))

        app.terminate()
        app = launch(reset: false)
        openSettings(app)
        XCTAssertTrue(app.buttons["Neutral"].isSelected)
        XCTAssertEqual(app.switches["settings.island"].value as? String, "0")
        XCTAssertTrue(showsValue(app).contains("Work"), showsValue(app))
    }
}
