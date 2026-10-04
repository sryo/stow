import XCTest
@testable import StowShared

final class WorkspaceRestoreTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testARestoredWorkspaceComesBackWhereItWasWithItsItems() {
        let first = model.workspaces[0].id
        let middle = model.createWorkspace(name: "Research", colorId: .ocean)
        model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        _ = model.createWorkspace(name: "Home", colorId: .ruby)
        let snapshot = model.workspaces[1]
        XCTAssertEqual(snapshot.id, middle)

        model.deleteWorkspace(id: middle, keepFavicons: true)
        XCTAssertEqual(model.workspaces.count, 2)
        model.restoreWorkspace(snapshot, at: 1)

        XCTAssertEqual(model.workspaces.map(\.id)[1], middle)
        XCTAssertEqual(model.workspaces[1].items, snapshot.items)
        XCTAssertEqual(model.workspaces[0].id, first)
        // It survives a reload from disk.
        let reloaded = AppModel(store: DataStore(baseDirectory: tempDir))
        XCTAssertEqual(reloaded.workspaces.map(\.id)[1], middle)
    }

    func testRestoringTwiceDoesNothing() {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        let snapshot = model.workspaces.first { $0.id == id }!
        model.deleteWorkspace(id: id, keepFavicons: true)
        model.restoreWorkspace(snapshot, at: 5)
        model.restoreWorkspace(snapshot, at: 0)
        XCTAssertEqual(model.workspaces.filter { $0.id == id }.count, 1)
        XCTAssertEqual(model.workspaces.last?.id, id, "an index past the end appends")
    }

    func testKeepingFaviconsLeavesTheIconFilesForAnUndo() throws {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        let icons = tempDir.appendingPathComponent("Icons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let icon = icons.appendingPathComponent("site.png")
        try Data([1, 2, 3]).write(to: icon)
        let linkId = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.updateLinkFaviconPath(id: linkId, path: icon.path)
        model.deleteWorkspace(id: id, keepFavicons: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
        model.cleanOrphanedFavicons()
        XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path), "cleaned once the undo window closes")
    }
}
