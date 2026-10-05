import XCTest

/// One Edit Workspace sheet, reached by long-pressing any workspace; every new workspace
/// goes through it; deletes and archives offer an Undo toast; widget links open through
/// the app. Saves screenshots when STOW_TOUR_DIR is set (TEST_RUNNER_STOW_TOUR_DIR).
final class EditWorkspaceUITests: XCTestCase {
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
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func card(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'workspace.card' AND label == %@", name)).firstMatch
    }

    private func cardCount(_ app: XCUIApplication) -> Int {
        app.buttons.matching(identifier: "workspace.card").count
    }

    private func pageTitle(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'page.title' AND label == %@", name)).firstMatch
    }

    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        element.exists && app.windows.firstMatch.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    private func openWorkspaces(_ app: XCUIApplication) {
        app.buttons["Workspaces"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5))
        sleep(1)
    }

    private func flickToNextPage(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: 2500, thenHoldForDuration: 0)
        sleep(1)
    }

    private var editorBar: (XCUIApplication) -> XCUIElement { { $0.navigationBars["Edit Workspace"] } }
    private var newBar: (XCUIApplication) -> XCUIElement { { $0.navigationBars["New Workspace"] } }

    // MARK: Long-press opens the editor

    func testLongPressOnACardOpensTheEditorAndEditsIconAndColor() {
        let app = launch()
        openWorkspaces(app)
        let home = card(app, "Home")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.press(forDuration: 0.8)
        XCTAssertTrue(editorBar(app).waitForExistence(timeout: 5), "long-press on a card opens Edit Workspace")
        XCTAssertEqual(app.textFields["editor.name"].value as? String, "Home")
        XCTAssertTrue(app.buttons["Open"].exists)
        XCTAssertTrue(app.buttons["Share…"].exists)
        XCTAssertTrue(app.buttons["Export…"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        sleep(1)
        snap("01-card-long-press-opens-editor")

        app.buttons["Symbol icon"].tap()
        XCTAssertTrue(app.buttons["book"].waitForExistence(timeout: 3))
        app.buttons["book"].tap()
        app.buttons["Periwinkle"].tap()
        XCTAssertTrue(app.buttons["Periwinkle"].isSelected)
        XCTAssertTrue(app.buttons["Symbol icon"].isSelected)
        sleep(1)
        snap("03-editor-icon-and-color")

        editorBar(app).buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5))
        sleep(1)
        snap("05-card-after-edit")

        // A tap still goes there.
        card(app, "Home").tap()
        XCTAssertFalse(app.navigationBars["Workspaces"].waitForExistence(timeout: 2))
        XCTAssertTrue(onScreen(app, pageTitle(app, "Home")))
    }

    func testLongPressOnThePageTitleOpensTheEditor() {
        let app = launch()
        let title = pageTitle(app, "Work")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.press(forDuration: 0.8)
        XCTAssertTrue(editorBar(app).waitForExistence(timeout: 5), "long-press on the page title opens Edit Workspace")
        XCTAssertEqual(app.textFields["editor.name"].value as? String, "Work")
        sleep(1)
        snap("02-page-title-long-press-opens-editor")

        let field = app.textFields["editor.name"]
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Office")
        editorBar(app).buttons["Done"].tap()
        XCTAssertTrue(pageTitle(app, "Office").waitForExistence(timeout: 5))
    }

    // MARK: New workspace

    func testTheNewWorkspaceCardGoesThroughTheEditor() {
        let app = launch()
        openWorkspaces(app)
        app.buttons["workspaces.new"].tap()
        XCTAssertTrue(newBar(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the empty name takes focus")
        XCTAssertFalse(newBar(app).buttons["Create"].isEnabled)
        snap("06-new-workspace-empty-focused")

        app.typeText("Nope")
        newBar(app).buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Workspaces"].waitForExistence(timeout: 5))
        XCTAssertFalse(card(app, "Nope").exists, "Cancel creates nothing")
        XCTAssertEqual(cardCount(app), 3)

        app.buttons["workspaces.new"].tap()
        XCTAssertTrue(newBar(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("Travel")
        app.buttons["Symbol icon"].tap()
        app.buttons["paperplane"].tap()
        sleep(1)
        snap("07-new-workspace-named")
        newBar(app).buttons["Create"].tap()
        XCTAssertTrue(pageTitle(app, "Travel").waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(onScreen(app, pageTitle(app, "Travel")), "the new workspace opens")
        snap("08-new-workspace-created")
    }

    func testSwipingPastTheLastPageOpensTheEditorAndCancelCreatesNothing() {
        let app = launch()
        XCTAssertTrue(pageTitle(app, "Work").waitForExistence(timeout: 5))
        flickToNextPage(app)
        flickToNextPage(app)
        XCTAssertTrue(onScreen(app, pageTitle(app, "Reading")))
        flickToNextPage(app)
        XCTAssertTrue(newBar(app).waitForExistence(timeout: 5), "swiping past the last page asks for a new workspace")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        snap("09-over-swipe-opens-new-workspace")

        newBar(app).buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(onScreen(app, pageTitle(app, "Reading")), "Cancel leaves you on the last workspace")
        snap("10-over-swipe-cancelled")
        openWorkspaces(app)
        XCTAssertEqual(cardCount(app), 3, "nothing is created silently")
        app.navigationBars["Workspaces"].buttons["Done"].tap()
        sleep(1)

        flickToNextPage(app)
        XCTAssertTrue(newBar(app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("Garden\n")
        XCTAssertTrue(pageTitle(app, "Garden").waitForExistence(timeout: 5), "Return creates it")
        sleep(1)
        XCTAssertTrue(onScreen(app, pageTitle(app, "Garden")))
    }

    // MARK: Undo toasts

    func testDeletingAWorkspaceOffersUndo() {
        let app = launch()
        openWorkspaces(app)
        card(app, "Reading").press(forDuration: 0.8)
        XCTAssertTrue(editorBar(app).waitForExistence(timeout: 5))
        app.buttons["Delete"].tap()
        let toast = app.staticTexts["Deleted “Reading”"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "deleting shows an Undo toast")
        XCTAssertEqual(cardCount(app), 2)
        snap("11-workspace-deleted-undo-toast")
        app.buttons["toast.undo"].firstMatch.tap()
        XCTAssertTrue(card(app, "Reading").waitForExistence(timeout: 5), "Undo brings it back")
        XCTAssertEqual(cardCount(app), 3)
    }

    func testArchivingARowOffersUndo() {
        let app = launch()
        let row = app.staticTexts["GitHub"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0))
            .withOffset(CGVector(dx: 0, dy: row.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -180, dy: 0)), withVelocity: 120, thenHoldForDuration: 0.2)
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3))
        archive.tap()
        let toast = app.staticTexts["Archived “GitHub”"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "archiving shows an Undo toast")
        sleep(1)
        snap("12-item-archived-undo-toast")
        app.buttons["toast.undo"].firstMatch.tap()
        sleep(1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Archive ·'")).firstMatch.exists,
                       "Undo puts the row back")
        XCTAssertFalse(toast.exists)
    }

    // MARK: Widget links

    /// The URL a widget tile on "Home" hands to the app: the app selects Home and opens
    /// the link in the browser.
    func testAWidgetLinkSelectsItsWorkspaceAndOpensTheLink() {
        let app = launch()
        XCTAssertTrue(pageTitle(app, "Work").waitForExistence(timeout: 5))
        var components = URLComponents(string: "stow://open")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://example.com"),
                                 URLQueryItem(name: "workspace", value: "44444444-4444-4444-4444-444444444402")]
        app.open(components.url!)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "the link opens in the browser")
        sleep(4)
        snap("13-widget-link-opened-in-safari")
        app.activate()
        XCTAssertTrue(pageTitle(app, "Home").waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertTrue(onScreen(app, pageTitle(app, "Home")), "the widget's workspace is selected")
        snap("14-widget-link-selected-home")
    }
}
