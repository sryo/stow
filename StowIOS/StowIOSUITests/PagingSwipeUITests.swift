import XCTest

/// A swipe across a row pages to the next workspace and never archives the row; the
/// archive action is still a slow drag and a tap away.
final class PagingSwipeUITests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/iOSSeed/settings-workspaces.json").path
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["STOW_SEED_FIXTURE_JSON"] = try! String(contentsOfFile: fixturePath, encoding: .utf8)
        app.launchEnvironment["STOW_RESET_SETTINGS"] = "1"
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["STOW_TOUR_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func onScreen(_ app: XCUIApplication, _ label: String) -> Bool {
        let element = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        return element.exists && app.windows.firstMatch.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    private func archiveHeader(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Archive ·'")).firstMatch
    }

    /// A quick horizontal flick across the row's full width, the way a thumb pages.
    private func flick(_ app: XCUIApplication, across label: String, left: Bool) {
        let row = app.staticTexts[label].firstMatch
        let window = app.windows.firstMatch
        let y = row.frame.midY
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0)).withOffset(CGVector(dx: 0, dy: y))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0)).withOffset(CGVector(dx: 0, dy: y))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: 2500, thenHoldForDuration: 0)
    }

    func testSwipingAcrossRowsPagesAndNeverArchives() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Swift Forums"].firstMatch.waitForExistence(timeout: 5))

        for round in 0..<4 {
            flick(app, across: round.isMultiple(of: 2) ? "Swift Forums" : "GitHub", left: true)
            sleep(1)
            if round == 0 { snap("swipe-1-paged-to-home") }
            XCTAssertTrue(onScreen(app, "Recipes"), "round \(round): swipe left should page to Home")
            flick(app, across: "Recipes", left: false)
            sleep(1)
            XCTAssertTrue(onScreen(app, "Swift Forums"), "round \(round): Swift Forums should be back, not archived")
            XCTAssertTrue(onScreen(app, "GitHub"), "round \(round): GitHub was archived")
            XCTAssertFalse(app.buttons["Archive"].exists, "round \(round): a row's actions were left open")
        }
        XCTAssertFalse(archiveHeader(app).exists)
    }

    func testASlowDragStillRevealsArchive() {
        let app = launch()
        let row = app.staticTexts["GitHub"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0))
            .withOffset(CGVector(dx: 0, dy: row.frame.midY))
        let end = start.withOffset(CGVector(dx: -180, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 120, thenHoldForDuration: 0.2)
        sleep(1)
        snap("swipe-2-slow-drag-reveals-archive")

        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3), "a slow drag should reveal Archive")
        XCTAssertTrue(onScreen(app, "Swift Forums"), "a slow drag on a row must not page")
        archive.tap()
        sleep(1)
        XCTAssertTrue(archiveHeader(app).waitForExistence(timeout: 3))
        snap("swipe-3-archived-by-tap")
    }
}
