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

    // MARK: - nested archive (unarchived / archivedLeaves)

    private func ids(_ nodes: [Node]) -> [UUID] { nodes.flattenIds() }

    func testUnarchived_dropsArchivedItemsAtEveryDepth() {
        let folder = model.addFolder(name: "Reading", parentId: nil)
        let keep = model.addLink(urlString: "https://a", title: "a", parentId: folder)
        let gone = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        model.archiveNode(id: gone)

        let shown = ids(model.currentWorkspace.items.unarchived())
        XCTAssertTrue(shown.contains(folder))
        XCTAssertTrue(shown.contains(keep))
        XCTAssertFalse(shown.contains(gone))
    }

    func testArchivedLeaves_bringsNestedArchivedItemsUpToTheArchive() {
        let folder = model.addFolder(name: "Reading", parentId: nil)
        _ = model.addLink(urlString: "https://a", title: "a", parentId: folder)
        let nested = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        let archivedFolder = model.addFolder(name: "Old", parentId: nil)
        let inside = model.addLink(urlString: "https://c", title: "c", parentId: archivedFolder)
        model.archiveNode(id: nested)
        model.archiveNode(id: archivedFolder)

        let archive = model.currentWorkspace.items.archivedLeaves()
        XCTAssertEqual(archive.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [nested, archivedFolder].sorted { $0.uuidString < $1.uuidString },
                       "the nested link joins the archive; the archived folder comes whole, not item by item")
        XCTAssertTrue(ids(archive).contains(inside))
    }

    func testUnarchivingANestedItemPutsItBackInItsFolder() {
        let folder = model.addFolder(name: "Reading", parentId: nil)
        let nested = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        model.archiveNode(id: nested)
        model.unarchiveNode(id: nested)

        XCTAssertTrue(ids(model.currentWorkspace.items.unarchived()).contains(nested))
        XCTAssertFalse(ids(model.currentWorkspace.items.archivedLeaves()).contains(nested))
        XCTAssertEqual(model.location(of: nested)?.parentId, folder)
    }

    // MARK: - permanent delete and restore (undo)

    func testRestoreNode_putsADeletedItemBackWhereItWas() throws {
        let folder = model.addFolder(name: "Trips", parentId: nil)
        _ = model.addLink(urlString: "https://a", title: "a", parentId: folder)
        let target = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        _ = model.addLink(urlString: "https://c", title: "c", parentId: folder)

        let removed = try XCTUnwrap(model.permanentlyDeleteNode(id: target))
        XCTAssertNil(model.nodeById(target))
        XCTAssertEqual(removed.location, NodeLocation(parentId: folder, index: 1))

        model.restoreNode(removed)
        XCTAssertEqual(model.location(of: target), NodeLocation(parentId: folder, index: 1))
        model.restoreNode(removed)
        XCTAssertEqual(model.currentWorkspace.items.flattenIds().filter { $0 == target }.count, 1,
                       "restoring twice doesn't duplicate")
    }

    func testRestoreNode_landsAtTheTopLevelWhenItsFolderIsGone() throws {
        let folder = model.addFolder(name: "Trips", parentId: nil)
        let target = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        let removed = try XCTUnwrap(model.permanentlyDeleteNode(id: target))
        model.permanentlyDeleteNode(id: folder)

        model.restoreNode(removed)
        XCTAssertEqual(model.location(of: target)?.parentId, nil)
    }

    func testRestoreNode_bringsBackAFolderWithItsChildren() throws {
        let folder = model.addFolder(name: "Trips", parentId: nil)
        let child = model.addLink(urlString: "https://b", title: "b", parentId: folder)
        let removed = try XCTUnwrap(model.permanentlyDeleteNode(id: folder))
        model.restoreNode(removed)
        XCTAssertEqual(model.location(of: child)?.parentId, folder)
    }

    // MARK: - new tasks (X6)

    func testNewTaskLandsAboveCompletedTasks() {
        let open = model.addTask(title: "Open", parentId: nil)
        let done = model.addTask(title: "Book flights", parentId: nil)
        model.toggleTaskCompletion(id: done)

        let new = model.addTask(title: "New", parentId: nil)
        let order = model.currentWorkspace.items.map(\.id).filter { [open, done, new].contains($0) }
        XCTAssertEqual(order, [open, new, done])
    }

    func testNewTaskInAFolderLandsAboveItsCompletedTasks() {
        let folder = model.addFolder(name: "Trip", parentId: nil)
        let done = model.addTask(title: "Book flights", parentId: folder)
        model.toggleTaskCompletion(id: done)
        let link = model.addLink(urlString: "https://a", title: "a", parentId: folder)

        let new = model.addTask(title: "Pack", parentId: folder)
        guard case .folder(let f)? = model.nodeById(folder) else { return XCTFail("no folder") }
        XCTAssertEqual(f.children.map(\.id), [new, done, link])
    }

    func testNewTaskWithNoCompletedTasksIsAppended() {
        let first = model.addTask(title: "One", parentId: nil)
        let new = model.addTask(title: "Two", parentId: nil)
        XCTAssertEqual(model.location(of: new)?.index, (model.location(of: first)?.index ?? -2) + 1)
    }

    // MARK: - defaults (G8)

    func testTheDefaultFolderNameIsSharedByEveryPlatform() {
        XCTAssertEqual(NodeDefaults.folderName, "Untitled")
    }
}
