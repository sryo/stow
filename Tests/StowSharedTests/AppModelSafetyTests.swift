import XCTest
@testable import StowShared

/// Covers the defensive guards added in commit f6c2df5: descendant guard on
/// moveNode, sync cycle guard on upsertNodeFromSync, and the ancestor-in-set
/// dedup on groupNodesInNewFolder.
final class AppModelSafetyTests: XCTestCase {

    private var tempDir: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - moveNode descendant guard

    func testMoveNode_rejectsMovingFolderIntoOwnDescendant() {
        let outer = model.addFolder(name: "outer", parentId: nil)
        let inner = model.addFolder(name: "inner", parentId: outer)

        model.moveNode(id: outer, toParentId: inner, index: 0)

        // outer should still be top-level; not nested inside inner
        XCTAssertNotNil(model.workspaces.first?.items.first(where: { $0.id == outer }))
    }

    func testMoveNode_acceptsLegitMoveBetweenSiblings() {
        let folderA = model.addFolder(name: "A", parentId: nil)
        let folderB = model.addFolder(name: "B", parentId: nil)
        let leaf = model.addLink(urlString: "https://x", title: "x", parentId: folderA)

        model.moveNode(id: leaf, toParentId: folderB, index: 0)

        if case .folder(let b) = model.workspaces.first!.items.first(where: { $0.id == folderB })! {
            XCTAssertEqual(b.children.first?.id, leaf)
        } else {
            XCTFail("folderB should be a folder")
        }
    }

    // MARK: - groupNodesInNewFolder ancestor-in-set dedup

    func testGroupInNewFolder_dropsDescendantWhenAncestorAlsoSelected() {
        let parentFolder = model.addFolder(name: "parent", parentId: nil)
        let childLink = model.addLink(urlString: "https://x", title: "x", parentId: parentFolder)

        let newFolderId = model.groupNodesInNewFolder(
            nodeIds: [parentFolder, childLink],
            folderName: "new"
        )

        XCTAssertNotNil(newFolderId)
        guard let newFolderNode = model.workspaces.first?.items.first(where: { $0.id == newFolderId }),
              case .folder(let newFolder) = newFolderNode else {
            XCTFail("New folder should exist"); return
        }
        // The descendant must NOT appear twice — once inside the parent it was moved with,
        // once at the top level of the new folder.
        XCTAssertEqual(newFolder.children.count, 1, "Only the ancestor should be at the top level")
        if case .folder(let movedParent) = newFolder.children[0] {
            XCTAssertEqual(movedParent.id, parentFolder)
            XCTAssertEqual(movedParent.children.first?.id, childLink, "Descendant stays nested inside its ancestor")
        }
    }

    func testGroupInNewFolder_acceptsUnrelatedSiblings() {
        let a = model.addLink(urlString: "https://a", title: "a", parentId: nil)
        let b = model.addLink(urlString: "https://b", title: "b", parentId: nil)

        let newFolderId = model.groupNodesInNewFolder(nodeIds: [a, b], folderName: "pair")

        guard case .folder(let folder) = model.workspaces.first?.items.first(where: { $0.id == newFolderId })! else {
            XCTFail("Expected folder"); return
        }
        XCTAssertEqual(folder.children.count, 2)
    }

    // MARK: - upsertNodeFromSync cycle guard

    func testUpsertFromSync_dropsSelfParentingRecord() {
        let workspaceId = model.workspaces.first!.id
        let folderId = UUID()
        let folder = Folder(id: folderId, name: "loop", children: [], isExpanded: true)

        let accepted = model.upsertNodeFromSync(
            node: .folder(folder),
            workspaceId: workspaceId,
            parentId: folderId  // node names itself as its own parent
        )

        // Returns true (handled, don't retry) but didn't insert.
        XCTAssertTrue(accepted)
        XCTAssertNil(model.nodeById(folderId))
    }

    func testUpsertFromSync_dropsRecordCreatingCycle() {
        let workspaceId = model.workspaces.first!.id
        let parentFolder = model.addFolder(name: "parent", parentId: nil)
        let childFolder = model.addFolder(name: "child", parentId: parentFolder)

        // Try to make `parent` a child of `child` (its own descendant) via sync.
        guard let parentNode = model.nodeById(parentFolder) else {
            XCTFail("parent folder missing"); return
        }
        let accepted = model.upsertNodeFromSync(
            node: parentNode,
            workspaceId: workspaceId,
            parentId: childFolder
        )

        XCTAssertTrue(accepted)
        // The original parent should still be where it was.
        let topLevel = model.workspaces.first!.items
        XCTAssertNotNil(topLevel.first(where: { $0.id == parentFolder }))
    }
}
