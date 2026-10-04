import XCTest

/// Screenshots of the Live Activity (Lock Screen and Dynamic Island), workspace badges and
/// the home screen icon. Runs only when STOW_TOUR_DIR is set (pass it as
/// TEST_RUNNER_STOW_TOUR_DIR to xcodebuild).
final class IdentityTourUITests: XCTestCase {
    private var tourDir: URL!

    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/iOSSeed/iphone-identity.json").path
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let dir = ProcessInfo.processInfo.environment["STOW_TOUR_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_STOW_TOUR_DIR to run the identity tour")
        }
        tourDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: tourDir, withIntermediateDirectories: true)
    }

    private func snap(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: tourDir.appendingPathComponent("\(name).png"))
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.debugDescription.write(to: tourDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    private func lock() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    }

    func testIdentityTour() {
        let app = XCUIApplication()
        app.launchEnvironment["STOW_SEED_FIXTURE_JSON"] = try! String(contentsOfFile: fixturePath, encoding: .utf8)
        app.launchEnvironment["STOW_RESET_SETTINGS"] = "1"
        app.launch()
        // Give the rows time to fetch and save their favicons.
        sleep(8)
        snap("50-personal-page")

        app.buttons["Workspaces"].firstMatch.tap()
        sleep(2)
        snap("51-workspaces-badges")
        dump(app, "51-workspaces-badges")
        let work = app.staticTexts["Work"].firstMatch
        let from = work.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -230, dy: 0)), withVelocity: 200, thenHoldForDuration: 0.3)
        sleep(1)
        snap("51b-workspaces-letter-and-symbol")
        let done = app.navigationBars["Workspaces"].buttons["Done"]
        if done.exists { done.tap() } else { app.swipeDown() }
        sleep(1)

        XCUIDevice.shared.press(.home)
        sleep(3)
        snap("52-home-icon-and-island")

        // Long-press the island to expand it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).press(forDuration: 1.2)
        sleep(2)
        snap("53-island-expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)

        lock()
        sleep(2)
        lock()
        sleep(3)
        snap("54-lock-screen")
        dump(springboard, "54-lock-screen")
    }
}
