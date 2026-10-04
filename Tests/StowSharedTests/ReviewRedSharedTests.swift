import XCTest
import Combine
import CloudKit
@testable import StowShared

/// Red tests from the 2026-10 review (review/red-tests.md). Each one shows a finding
/// in the shared model or sync layer and fails until that finding is fixed.
final class ReviewRedSharedTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDown() {
        model = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func node(_ id: UUID, in workspaceId: UUID) -> Node? {
        func find(_ nodes: [Node]) -> Node? {
            for node in nodes {
                if node.id == id { return node }
                if case .folder(let folder) = node, let hit = find(folder.children) { return hit }
            }
            return nil
        }
        return model.workspaces.first { $0.id == workspaceId }.flatMap { find($0.items) }
    }

    /// A second workspace, selected, holding one link and one task.
    private func secondWorkspace() -> (id: UUID, link: UUID, task: UUID) {
        let id = model.createWorkspace(name: "Second", colorId: .ocean)
        let link = model.addLink(urlString: "https://example.org", title: "Example", parentId: nil)
        let task = model.addTask(title: "Reply", parentId: nil)
        XCTAssertNotEqual(model.workspaces.first?.id, id, "precondition: the second workspace isn't the first")
        return (id, link, task)
    }

    // MARK: code-health-1

    func testFaviconForALinkOutsideTheFirstWorkspaceIsSavedWhileOnSettings() {
        let second = secondWorkspace()
        model.selectSettings()
        model.updateLinkFaviconPath(id: second.link, path: "/tmp/icon.png")
        guard case .link(let link)? = node(second.link, in: second.id) else { return XCTFail("link missing") }
        XCTAssertEqual(link.faviconPath, "/tmp/icon.png",
                       "code-health-1: updateLinkFaviconPath only searches currentWorkspace, which is the first workspace on Settings")
    }

    // MARK: code-health-2

    func testTogglingATaskWhileOnSettingsTicksItInItsOwnWorkspace() {
        let second = secondWorkspace()
        model.selectSettings()
        model.toggleTaskCompletion(id: second.task)
        guard case .task(let task)? = node(second.task, in: second.id) else { return XCTFail("task missing") }
        XCTAssertTrue(task.isCompleted,
                      "code-health-2: on Settings currentWorkspace falls back to the first workspace, so the Tabline's task toggle is lost")
    }

    // MARK: code-health-5

    func testWorkspaceIconSurvivesTheCloudKitRecord() {
        let workspace = Workspace(id: UUID(), name: "Home", colorId: .ocean, items: [], icon: .symbol("star"))
        let record = RecordConverter.workspaceToCKRecord(workspace: workspace, sortOrder: 0, zoneID: CKRecordZone.ID(zoneName: "TestZone"))
        let decoded = RecordConverter.ckRecordToWorkspace(record: record)
        XCTAssertEqual(decoded?.icon, .symbol("star"), "code-health-5: RecordConverter writes no icon field")
    }

    func testIncomingWorkspaceRecordUpdatesTheIcon() {
        let local = model.currentWorkspace
        var remote = local
        remote.icon = .letter
        model.updateWorkspaceFromSync(remote)
        XCTAssertEqual(model.workspaces.first { $0.id == local.id }?.icon, .letter,
                       "code-health-5: updateWorkspaceFromSync copies only name, colorId and browserProfiles")
    }

    // MARK: code-health-4

    @MainActor
    func testFinishingASyncFetchNotifiesChangesSubscribers() {
        var emitted = 0
        let subscription = model.changes.sink { emitted += 1 }
        defer { subscription.cancel() }
        CloudSyncManager.notifyMergeFinished(model)
        XCTAssertEqual(emitted, 1,
                       "code-health-4: a fetch only calls the legacy onChange, so iOS (which listens on `changes`) never refreshes")
    }

    // MARK: patterns-12

    func testMacPublishesItsPageColorWhenICloudHasNone() {
        let store = RedMemoryStore()
        let local = scratchDefaults()
        local.set("subtle", forKey: PageColorSync.key)
        PageColorSync(store: store, defaults: local).adoptRemote()
        XCTAssertEqual(store.values[PageColorSync.key], "subtle",
                       "patterns-12: PageColorSync.adoptRemote never publishes the local choice, unlike SyncedTintPreference.start()")
    }
}

private final class RedMemoryStore: PageColorKeyValueStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? String }
    @discardableResult func synchronize() -> Bool { true }
}
