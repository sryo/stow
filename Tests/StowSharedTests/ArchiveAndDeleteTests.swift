import XCTest
@testable import StowShared

/// Exercises archive/unarchive/permanentlyDeleteNode, including the
/// deletionScheduler hook used to verify CloudKit deletion sets without
/// touching real CloudKit.
final class ArchiveAndDeleteTests: XCTestCase {

    private var tempDir: URL!
    private var model: AppModel!
    private var scheduledDeletions: [Set<UUID>] = []

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        scheduledDeletions = []
        model.deletionScheduler = { [weak self] ids in
            self?.scheduledDeletions.append(ids)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - archive / unarchive

    func testArchive_flipsFlagWithoutSchedulingDeletion() {
        let id = model.addLink(urlString: "https://x", title: "x", parentId: nil)
        model.archiveNode(id: id)

        guard let node = model.nodeById(id), case .link(let link) = node else {
            XCTFail("Expected link"); return
        }
        XCTAssertTrue(link.isArchived)
        XCTAssertTrue(scheduledDeletions.isEmpty, "Archive must NOT schedule CK deletion")
    }

    func testUnarchive_clearsFlag() {
        let id = model.addTask(title: "T", parentId: nil)
        model.archiveNode(id: id)
        model.unarchiveNode(id: id)

        guard let node = model.nodeById(id), case .task(let task) = node else { XCTFail(); return }
        XCTAssertFalse(task.isArchived)
    }

    func testArchive_idempotent() {
        let id = model.addLink(urlString: "https://x", title: "x", parentId: nil)
        model.archiveNode(id: id)
        model.archiveNode(id: id)  // second call

        guard let node = model.nodeById(id), case .link(let link) = node else { XCTFail(); return }
        XCTAssertTrue(link.isArchived)
        XCTAssertTrue(scheduledDeletions.isEmpty)
    }

    // MARK: - permanentlyDeleteNode

    func testPermanentDelete_leafSchedulesSelfOnly() {
        let id = model.addLink(urlString: "https://x", title: "x", parentId: nil)
        model.permanentlyDeleteNode(id: id)

        XCTAssertNil(model.nodeById(id))
        XCTAssertEqual(scheduledDeletions.count, 1)
        XCTAssertEqual(scheduledDeletions[0], [id])
    }

    func testPermanentDelete_folderSchedulesItselfAndChildren() {
        let folderId = model.addFolder(name: "f", parentId: nil)
        let child1 = model.addLink(urlString: "https://a", title: "a", parentId: folderId)
        let child2 = model.addTask(title: "b", parentId: folderId)

        model.permanentlyDeleteNode(id: folderId)

        XCTAssertNil(model.nodeById(folderId))
        XCTAssertEqual(scheduledDeletions.count, 1)
        let scheduled = scheduledDeletions[0]
        XCTAssertEqual(scheduled, [folderId, child1, child2])
    }

    func testPermanentDelete_deeplyNestedFolderCollectsAllDescendants() {
        let outer = model.addFolder(name: "outer", parentId: nil)
        let middle = model.addFolder(name: "middle", parentId: outer)
        let inner = model.addFolder(name: "inner", parentId: middle)
        let leaf = model.addLink(urlString: "https://leaf", title: "l", parentId: inner)

        model.permanentlyDeleteNode(id: outer)

        let scheduled = scheduledDeletions[0]
        XCTAssertEqual(scheduled, [outer, middle, inner, leaf])
    }

    func testPermanentDelete_emptyFolderSchedulesOnlySelf() {
        let folderId = model.addFolder(name: "empty", parentId: nil)
        model.permanentlyDeleteNode(id: folderId)
        XCTAssertEqual(scheduledDeletions[0], [folderId])
    }

    // MARK: - deleteWorkspace

    func testDeleteWorkspace_schedulesWorkspaceAndEveryNodeId() {
        let secondWsId = model.createWorkspace(name: "second", colorId: .defaultColor())
        let folderId = model.addFolder(name: "f", parentId: nil)
        let leafId = model.addLink(urlString: "https://x", title: "x", parentId: folderId)

        model.deleteWorkspace(id: secondWsId)

        let scheduled = scheduledDeletions[0]
        XCTAssertTrue(scheduled.contains(secondWsId), "Workspace id should be scheduled")
        XCTAssertTrue(scheduled.contains(folderId))
        XCTAssertTrue(scheduled.contains(leafId))
    }

    func testDeleteWorkspace_doesNothingIfOnlyOneWorkspace() {
        let lastId = model.workspaces[0].id
        model.deleteWorkspace(id: lastId)

        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertTrue(scheduledDeletions.isEmpty)
    }
}
