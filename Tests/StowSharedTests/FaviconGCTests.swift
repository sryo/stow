import XCTest
@testable import StowShared

/// Covers DataStore.cleanOrphanedFavicons — favicons are cached per-host and
/// shared across links, and FaviconService resolves icons by host-derived
/// filename even when faviconPath is nil, so the sweep must keep a file while
/// EITHER reference form still exists.
final class FaviconGCTests: XCTestCase {

    private var tempDir: URL!
    private var store: DataStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-favgc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DataStore(baseDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeIcon(_ name: String) throws -> URL {
        let url = store.iconsDirectory().appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        return url
    }

    private func makeState(links: [Link]) -> AppState {
        let workspace = Workspace(id: UUID(), name: "w", colorId: .ocean, items: links.map { .link($0) })
        return AppState(schemaVersion: DataStore.currentSchemaVersion, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)
    }

    func testSweep_deletesUnreferencedIcons() throws {
        let orphan = try makeIcon("gone.example.ico")
        store.cleanOrphanedFavicons(state: makeState(links: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testSweep_keepsIconReferencedByFaviconPath() throws {
        let icon = try makeIcon("kept.example.ico")
        let link = Link(id: UUID(), title: "t", url: "https://unrelated.test", faviconPath: icon.path)
        store.cleanOrphanedFavicons(state: makeState(links: [link]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
    }

    func testSweep_keepsIconDerivableFromLinkHost() throws {
        // faviconPath is nil, but FaviconService would resolve this file from
        // the link's host at display time — it must survive the sweep.
        let icon = try makeIcon("example.com.ico")
        let link = Link(id: UUID(), title: "t", url: "https://EXAMPLE.com/page", faviconPath: nil)
        store.cleanOrphanedFavicons(state: makeState(links: [link]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
    }

    func testSweep_seesLinksNestedInFolders() throws {
        let icon = try makeIcon("nested.example.ico")
        let link = Link(id: UUID(), title: "t", url: "https://unrelated.test", faviconPath: icon.path)
        let folder = Folder(id: UUID(), name: "f", children: [.link(link)], isExpanded: true)
        let workspace = Workspace(id: UUID(), name: "w", colorId: .ocean, items: [.folder(folder)])
        let state = AppState(schemaVersion: DataStore.currentSchemaVersion, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)
        store.cleanOrphanedFavicons(state: state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path))
    }

    func testSweep_withoutIconsDirectoryIsANoOp() {
        store.cleanOrphanedFavicons(state: makeState(links: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Icons").path), "Sweep must not create the Icons directory")
    }

    func testPermanentDelete_removesOrphanedIcon() throws {
        let model = AppModel(store: store)
        let icon = try makeIcon("deleted.example.ico")
        let linkId = model.addLink(urlString: "https://deleted.example", title: "t", parentId: nil)
        model.updateLinkFaviconPath(id: linkId, path: icon.path)
        model.permanentlyDeleteNode(id: linkId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path))
    }
}
