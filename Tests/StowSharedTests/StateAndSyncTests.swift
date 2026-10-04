import XCTest
import Combine
import CloudKit
@testable import StowShared

/// The active workspace on Settings, change origins, one stow path and the workspace
/// icon in sync.
final class StateAndSyncTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDown() {
        model = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var dataFile: URL { tempDir.appendingPathComponent("data.json") }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: dataFile.path)[.modificationDate] as? Date
    }

    private func links(in workspaceId: UUID) -> [Link] {
        model.workspaces.first { $0.id == workspaceId }?.items.flattenLinks() ?? []
    }

    // MARK: Active workspace on Settings

    func testSettingsKeepsTheWorkspaceYouCameFromActive() {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectSettings()
        XCTAssertTrue(model.state.isSettingsSelected)
        XCTAssertEqual(model.activeWorkspaceId, second)
        XCTAssertEqual(model.activeWorkspace.name, "Second")
    }

    func testAddingAnItemOnSettingsLandsInTheActiveWorkspace() {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectSettings()
        let id = model.addTask(title: "Later", parentId: nil)
        XCTAssertTrue(model.workspaces.first { $0.id == second }!.items.contains { $0.id == id })
    }

    func testDeletingTheActiveWorkspaceOnSettingsFallsBackToAnotherOne() {
        let first = model.workspaces[0].id
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectSettings()
        model.deleteWorkspace(id: second)
        XCTAssertEqual(model.activeWorkspaceId, first)
    }

    func testNodeLookupFindsNodesInAnyWorkspace() {
        let first = model.workspaces[0].id
        let id = model.addLink(urlString: "https://a.test", title: "A", parentId: nil)
        model.createWorkspace(name: "Second", colorId: .ocean)
        XCTAssertNotNil(model.nodeById(id))
        model.renameNode(id: id, newName: "Renamed")
        XCTAssertEqual(links(in: first).first?.title, "Renamed")
    }

    // MARK: Favicons

    func testAnUnchangedFaviconPathDoesNotRewriteTheLibrary() throws {
        let id = model.addLink(urlString: "https://a.test", title: "A", parentId: nil)
        model.updateLinkFaviconPath(id: id, path: "/tmp/a.png")
        var emitted = 0
        let subscription = model.changes.sink { emitted += 1 }
        defer { subscription.cancel() }
        let before = modificationDate()
        Thread.sleep(forTimeInterval: 0.02)
        model.updateLinkFaviconPath(id: id, path: "/tmp/a.png")
        model.updateLinkFaviconPath(id: UUID(), path: "/tmp/b.png")
        XCTAssertEqual(emitted, 0, "nothing changed, so nothing reloads")
        XCTAssertEqual(modificationDate(), before, "nothing changed, so data.json isn't rewritten")
    }

    // MARK: Change origins

    func testExternalChangesAreMarkedAsSuch() {
        var origins: [AppModel.ChangeOrigin] = []
        let subscription = model.changeOrigins.sink { origins.append($0) }
        defer { subscription.cancel() }
        model.addTask(title: "Local", parentId: nil)
        model.notifyExternalChange()
        XCTAssertEqual(origins, [.local, .external],
                       "hosts upload only local changes, so a fetch isn't echoed back to iCloud")
    }

    // MARK: One stow path

    func testStowingPutsTheLinkAtTheTopInOneSave() {
        model.addLink(urlString: "https://old.test", title: "Old", parentId: nil)
        var emitted = 0
        let subscription = model.changes.sink { emitted += 1 }
        defer { subscription.cancel() }
        let result = model.stowLink(url: URL(string: "https://new.test/page")!, title: "New", workspaceId: nil)
        guard case .added(let id) = result else { return XCTFail("expected a new link") }
        XCTAssertEqual(model.currentWorkspace.items.first?.id, id)
        XCTAssertEqual(emitted, 1, "one persist, one notification")
    }

    func testStowingAnAlreadySavedURLReportsIt() {
        let id = model.addLink(urlString: "https://Example.test/page#top", title: "Page", parentId: nil)
        let result = model.stowLink(url: URL(string: "https://example.test/page")!, title: "Page", workspaceId: nil)
        XCTAssertEqual(result, .alreadyPresent(id))
        XCTAssertEqual(model.currentWorkspace.items.flattenLinks().count, 1)
    }

    func testStowingIntoAnotherWorkspaceLeavesTheSelectionAlone() {
        let first = model.workspaces[0].id
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectWorkspace(id: first)
        let result = model.stowLink(url: URL(string: "https://x.test")!, title: "X", workspaceId: second)
        guard case .added = result else { return XCTFail("expected a new link") }
        XCTAssertEqual(links(in: second).map(\.url), ["https://x.test"])
        XCTAssertEqual(model.state.selectedWorkspaceId, first)
    }

    func testCanonicalKeyIgnoresCaseFragmentAndRootSlash() {
        XCTAssertEqual(URLCanonical.key(URL(string: "HTTPS://Example.COM/#x")!), "https://example.com")
        XCTAssertEqual(URLCanonical.key(URL(string: "https://example.com/a?id=1")!), "https://example.com/a?id=1")
    }

    // MARK: Workspace icon in sync

    func testOldWorkspaceRecordsWithoutAnIconDecodeAsFavicons() {
        let workspace = Workspace(id: UUID(), name: "Home", colorId: .ocean, items: [], icon: .letter)
        let record = RecordConverter.workspaceToCKRecord(workspace: workspace, sortOrder: 0, zoneID: CKRecordZone.ID(zoneName: "TestZone"))
        record[CKWorkspaceFields.icon] = nil
        XCTAssertEqual(RecordConverter.ckRecordToWorkspace(record: record)?.icon, .favicons)
    }

    func testNameMergeCopiesTheIcon() {
        let local = model.workspaces[0]
        let remote = Workspace(id: UUID(), name: local.name, colorId: .ocean, items: [], icon: .symbol("star"))
        model.mergeWorkspaceMetadataFromSync(remote: remote, intoWorkspaceId: local.id)
        XCTAssertEqual(model.workspaces[0].icon, .symbol("star"))
    }
}
