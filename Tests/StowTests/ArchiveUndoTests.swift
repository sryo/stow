import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Archive, permanent delete and their undo; the one toast; the stow results it reports.
@MainActor
final class ArchiveUndoTests: XCTestCase {
    private var harness: RedHarness!
    private var model: AppModel { harness.model }

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        Toast.dismiss(expired: false)
        harness.tearDown()
        harness = nil
    }

    private var undoManager: UndoManager? { harness.window.undoManager }

    private func visibleIds() -> Set<UUID> {
        Set((0..<200).compactMap { harness.nodeList.visibleNode(at: $0)?.id })
    }

    // MARK: - PendingChange

    func testArchiveCanBeUndone() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Lisbon", parentId: nil)
        let change = try XCTUnwrap(PendingChange.archive([id], model: model))
        XCTAssertEqual(change.message, "Archived “Lisbon”")
        XCTAssertEqual(model.nodeById(id)?.isArchived, true)
        change.undo()
        XCTAssertEqual(model.nodeById(id)?.isArchived, false)
    }

    func testArchiveStillUndoesAfterTheToastIsGone() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Lisbon", parentId: nil)
        let change = try XCTUnwrap(PendingChange.archive([id], model: model))
        change.expire()
        change.undo()
        XCTAssertEqual(model.nodeById(id)?.isArchived, false, "an archive has nothing to clean up, so ⌘Z keeps working")
    }

    func testBulkArchiveUndoesEveryItem() throws {
        let ids = (0..<3).map { model.addLink(urlString: "https://site\($0).example", title: "Site \($0)", parentId: nil) }
        let change = try XCTUnwrap(PendingChange.archive(ids, model: model))
        XCTAssertEqual(change.message, "Archived 3 items")
        change.undo()
        XCTAssertTrue(ids.allSatisfy { model.nodeById($0)?.isArchived == false })
    }

    func testArchivingWhatsAlreadyArchivedOffersNoUndo() {
        let id = model.addLink(urlString: "https://example.com", title: "Lisbon", parentId: nil)
        model.archiveNode(id: id)
        XCTAssertNil(PendingChange.archive([id], model: model))
    }

    func testPermanentDeleteCanBeUndoneInPlace() throws {
        let folder = model.addFolder(name: "Trips", parentId: nil)
        _ = model.addLink(urlString: "https://a.example", title: "A", parentId: folder)
        let id = model.addLink(urlString: "https://b.example", title: "Lisbon", parentId: folder)
        model.archiveNode(id: id)
        let change = try XCTUnwrap(PendingChange.deletePermanently(id, model: model))
        XCTAssertEqual(change.message, "Deleted “Lisbon”")
        XCTAssertNil(model.nodeById(id))
        change.undo()
        XCTAssertEqual(model.location(of: id), NodeLocation(parentId: folder, index: 1))
        XCTAssertEqual(model.nodeById(id)?.isArchived, true, "it comes back archived, where it was")
    }

    func testPermanentDeleteCantBeUndoneAfterTheToastExpires() throws {
        let id = model.addLink(urlString: "https://b.example", title: "Lisbon", parentId: nil)
        let change = try XCTUnwrap(PendingChange.deletePermanently(id, model: model))
        change.expire()
        change.undo()
        XCTAssertNil(model.nodeById(id))
    }

    // MARK: - Wiring in the window

    func testPermanentDeleteFromTheListRegistersAnUndo() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.archiveNode(id: id)
        harness.host(width: 400)
        harness.nodeList.onNodePermanentlyDeleted?(id)
        XCTAssertNil(model.nodeById(id))
        XCTAssertEqual(undoManager?.canUndo, true)
        undoManager?.undo()
        XCTAssertNotNil(model.nodeById(id))
    }

    func testBulkArchiveFromTheListRegistersAnUndo() {
        let ids = (0..<2).map { model.addLink(urlString: "https://site\($0).example", title: "Site \($0)", parentId: nil) }
        harness.host(width: 400)
        harness.nodeList.onBulkNodesDeleted?(ids)
        XCTAssertEqual(undoManager?.canUndo, true)
        undoManager?.undo()
        XCTAssertTrue(ids.allSatisfy { model.nodeById($0)?.isArchived == false })
    }

    func testArchiveShowsTheToastAndItsUndoButtonWorks() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        harness.nodeList.onNodeDeleted?(id)
        harness.spin() // the event's undo group closes
        XCTAssertEqual(Toast.currentMessage, "Archived “Example”")
        Toast.performAction()
        XCTAssertEqual(model.nodeById(id)?.isArchived, false)
        XCTAssertFalse(Toast.isShowing)
        XCTAssertEqual(undoManager?.canUndo, false, "the toast's Undo takes the ⌘Z entry with it")
    }

    func testUndoingWithCommandZClosesTheToast() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        harness.nodeList.onNodeDeleted?(id)
        undoManager?.undo()
        XCTAssertFalse(Toast.isShowing)
    }

    func testANestedArchivedItemShowsInTheArchiveAndComesBack() {
        let folder = model.addFolder(name: "Reading", parentId: nil, isExpanded: true)
        let id = model.addLink(urlString: "https://example.com/b", title: "Gone", parentId: folder)
        model.archiveNode(id: id)
        model.setArchiveExpanded(workspaceId: model.currentWorkspace.id, isExpanded: true)
        harness.host(width: 400)
        let archived = (0..<200).contains { index in
            harness.nodeList.visibleNode(at: index)?.id == id && harness.nodeList.isArchivedRow(at: index)
        }
        XCTAssertTrue(archived, "the nested archived link is listed in the Archive section")
        harness.nodeList.onNodeUnarchived?(id)
        harness.spin(0.1)
        XCTAssertEqual(model.location(of: id)?.parentId, folder)
        XCTAssertTrue(visibleIds().contains(id))
    }

    // MARK: - Toast (C8)

    func testWorkspaceDeleteStillShowsItsUndoToast() {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        harness.host(width: 400)
        WorkspaceDeletion.delete(id, model: model, in: harness.window)
        XCTAssertEqual(Toast.currentMessage, "Deleted “Research”")
        Toast.performAction()
        XCTAssertTrue(model.workspaces.contains { $0.id == id })
    }

    func testCopyingASnippetInTheRailSaysCopied() throws {
        let id = model.addSnippet(title: "Greeting", content: "hello", language: nil, parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        let rail = try XCTUnwrap(harness.controller.view.descendants(of: RailView.self).first)
        rail.onCopySnippet?(id)
        XCTAssertEqual(Toast.currentMessage, "Copied")
    }

    func testStowingAPageThatsAlreadySavedSaysWhere() throws {
        let workspaceName = model.currentWorkspace.name
        _ = model.addLink(urlString: "https://example.com/page", title: "Page", parentId: nil)
        harness.host(width: 400)
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        harness.controller.stow(url: url, title: "Page", into: model.currentWorkspace.id)
        XCTAssertEqual(Toast.currentMessage, "Already in \(workspaceName)")
    }

    func testStowWithoutAutomationPermissionOffersAFix() {
        setenv("STOW_NO_AUTOMATION", "Arc", 1)
        defer { unsetenv("STOW_NO_AUTOMATION") }
        harness.host(width: 400)
        harness.controller.reportFrontTabUnavailable()
        XCTAssertEqual(Toast.currentMessage, "Allow Stow to control Arc")
    }

    // MARK: - Workspace tab drop hook (G2 prep)

    func testADropOnAWorkspaceTabMovesTheItem() throws {
        let other = model.createWorkspace(name: "Personal", colorId: .ocean)
        let home = model.workspaces[0].id
        model.selectWorkspace(id: home)
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        let strip = try XCTUnwrap(harness.controller.view.descendants(of: WorkspaceStripView.self).first)
        strip.onDropNode?(id, other)
        XCTAssertTrue(model.workspaces.first { $0.id == other }?.items.contains { $0.id == id } == true)
    }

    // MARK: - New folder name (G8)

    func testANewFolderIsCalledTheSharedDefault() {
        harness.host(width: 400)
        harness.controller.createFolderAndBeginRename(parentId: nil)
        XCTAssertTrue(model.currentWorkspace.items.contains { $0.displayName == NodeDefaults.folderName })
    }
}
