import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Every stow says what happened exactly once, on the surface it happened on:
/// "Stowed in X" for a new page, "Already in X" for one that's saved.
@MainActor
final class StowToastTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!
    private var links: LinkActions!
    private var shown: [String] = []

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-toast-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        model.renameWorkspace(id: model.activeWorkspaceId, newName: "Research")
        links = LinkActions(model: model, window: { nil })
        shown = []
        links.presentToast = { [unowned self] message, _ in self.shown.append("window: \(message)") }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private let page = URL(string: "ftp://example.com/a-page")!   // not http, so no title fetch

    func testStowingANewPageSaysStowedOnce() {
        links.stow(url: page, title: "A page", into: nil)
        XCTAssertEqual(shown, ["window: Stowed in Research"])
    }

    func testStowingASavedPageSaysAlreadyOnce() {
        links.stow(url: page, title: "A page", into: nil)
        shown = []
        links.stow(url: page, title: "A page", into: nil)
        XCTAssertEqual(shown, ["window: Already in Research"])
    }

    func testACallerCanPutTheToastOnItsOwnSurface() {
        links.stow(url: page, title: "A page", into: nil) { [unowned self] message, _ in self.shown.append("strip: \(message)") }
        XCTAssertEqual(shown, ["strip: Stowed in Research"])
    }

    // MARK: The Tabline's ghost tab

    private func stowGhostTwice() -> (first: [String], second: [String]) {
        let tabline = TablineController.shared
        let savedStow = tabline.onStowURL
        let savedToast = tabline.presentToast
        defer { tabline.onStowURL = savedStow; tabline.presentToast = savedToast }
        tabline.presentToast = { [unowned self] message, _ in self.shown.append("strip: \(message)") }
        // As MainViewController wires it.
        tabline.onStowURL = { [links] url, title, toast in links!.stow(url: url, title: title, into: nil, toast: toast) }
        let ghost = TablineGhost(url: page, title: "A page", host: "example.com")
        tabline.stowGhost(ghost)
        let first = shown
        shown = []
        tabline.stowGhost(ghost)
        return (first, shown)
    }

    func testTheGhostTabSaysStowedOnceUnderTheStrip() {
        XCTAssertEqual(stowGhostTwice().first, ["strip: Stowed in Research"])
    }

    func testTheGhostTabSaysAlreadyOnceUnderTheStrip() {
        XCTAssertEqual(stowGhostTwice().second, ["strip: Already in Research"],
                       "a saved page from the ghost tab toasted in the window and under the strip")
    }
}
