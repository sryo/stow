import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Red tests from the 2026-10 review for the list, sidebar and mosaic, and the
/// paths they share with the rail and the Tabline (review/red-tests.md).
@MainActor
final class ReviewRedListTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func visibleNodeIds() -> Set<UUID> {
        Set((0..<200).compactMap { harness.nodeList.visibleNode(at: $0)?.id })
    }

    // MARK: modes-2

    func testArchivingALinkInsideAFolderTakesItOffTheSidebar() {
        let folder = model.addFolder(name: "Reading", parentId: nil, isExpanded: true)
        let keep = model.addLink(urlString: "https://example.com/a", title: "Keep", parentId: folder)
        let gone = model.addLink(urlString: "https://example.com/b", title: "Gone", parentId: folder)
        model.archiveNode(id: gone)
        harness.host(width: 400)
        let ids = visibleNodeIds()
        XCTAssertTrue(ids.contains(keep), "precondition: the folder is expanded in the sidebar")
        XCTAssertFalse(ids.contains(gone),
                       "modes-2: MainViewController filters isArchived at the top level only, so a nested archived link stays in the list")
    }

    // MARK: modes-3

    func testRenameStartsOnAMosaicTile() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 900)
        XCTAssertEqual(harness.nodeList.elasticMode, .mosaic, "precondition: 900pt is mosaic")
        harness.nodeList.scheduleInlineRename(for: id)
        harness.nodeList.reloadData(with: model.currentWorkspace.items, forceExpand: false)
        harness.spin(0.2)
        XCTAssertEqual(harness.nodeList.inlineRenameNodeId, id,
                       "modes-3: handlePendingInlineRename and beginInlineRename only accept NodeCollectionViewItem, never NodeTileItem")
    }

    // MARK: modes-7

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    func testDownArrowInTheMosaicMovesToTheTileBelow() {
        let ids = (0..<8).map { model.addLink(urlString: "https://site\($0).example", title: "Site \($0)", parentId: nil) }
        harness.host(width: 900)
        let list = harness.nodeList
        XCTAssertEqual(list.elasticMode, .mosaic, "precondition: 900pt is mosaic")
        guard let collection = list.view.descendants(of: NSCollectionView.self).first else { return XCTFail("no collection view") }
        func frame(of id: UUID) -> NSRect? {
            (0..<collection.numberOfItems(inSection: 0)).first { list.visibleNode(at: $0)?.id == id }
                .flatMap { collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        }
        var activated: UUID?
        list.onNodeSelected = { activated = $0 }
        _ = list.handleListKey(key(125)) // reveals the cursor on the first tile
        let start = list.visibleNode(at: (0..<20).first { list.visibleNode(at: $0) != nil } ?? 0)?.id
        _ = list.handleListKey(key(125))
        _ = list.handleListKey(key(36))
        guard let start, let activated, let from = frame(of: start), let to = frame(of: activated) else {
            return XCTFail("nothing activated")
        }
        XCTAssertGreaterThan(Set(ids.compactMap { frame(of: $0)?.minY }).count, 1, "precondition: the tiles wrap onto more than one line")
        XCTAssertGreaterThan(abs(to.minY - from.minY), 1,
                             "modes-7: ↓ in the mosaic steps to the next tile in list order (same line, \(from.minX)→\(to.minX)), not the tile below")
    }

    // MARK: modes-5

    func testJumpModeIsNotTurnedOnForTheHiddenListInTheRail() {
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        XCTAssertTrue(harness.nodeList.hasNodeRows, "precondition: the hidden list still has rows")
        harness.controller.toggleJumpMode()
        XCTAssertFalse(harness.nodeList.isJumpModeActive,
                       "modes-5: toggleJumpMode (and ⌘-hold) never checks elasticMode, so letters open links in the hidden list")
    }

    // MARK: modes-8

    func testTheListAcceptsAURLDraggedFromTheBrowser() {
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        guard let collection = harness.nodeList.view.descendants(of: NSCollectionView.self).first else {
            return XCTFail("no collection view")
        }
        XCTAssertTrue(collection.registeredDraggedTypes.contains(.URL),
                      "modes-8: the collection view registers only nodePasteboardType; only EmptyStateView takes .URL")
    }

    // MARK: modes-9

    func testDroppingAnItemOnAWorkspaceTabIsPossibleAtSidebarWidth() {
        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        strip.workspaces = [.init(id: UUID(), name: "A", colorId: .ocean), .init(id: UUID(), name: "B", colorId: .moss)]
        strip.layoutSubtreeIfNeeded()
        let types = Set(([strip] + strip.descendants(of: NSView.self)).flatMap(\.registeredDraggedTypes))
        XCTAssertTrue(types.contains(nodePasteboardType),
                      "modes-9: only the rail's dots take a dropped item; WorkspaceStripView registers no drag types")
    }

    // MARK: code-health-10 / modes-16

    func testStowingFromTheTablineLandsAtTheTop() {
        _ = model.addLink(urlString: "https://example.com/old", title: "Old", parentId: nil)
        harness.host(width: 400)
        TablineController.shared.onStowURL?(URL(string: "https://stow.invalid/new")!, "New") { _, _ in }
        guard case .link(let first)? = model.currentWorkspace.items.first else { return XCTFail("no items") }
        XCTAssertEqual(first.url, "https://stow.invalid/new",
                       "code-health-10/modes-16: the Tabline ghost appends at the bottom; stowFrontTab inserts at index 0")
    }

    func testStowingTheSameTabTwiceFromTheTablineKeepsOneLink() {
        harness.host(width: 400)
        let url = URL(string: "https://stow.invalid/same")!
        TablineController.shared.onStowURL?(url, "Same") { _, _ in }
        TablineController.shared.onStowURL?(url, "Same") { _, _ in }
        let count = model.currentWorkspace.items.filter { if case .link(let l) = $0 { return l.url == url.absoluteString }; return false }.count
        XCTAssertEqual(count, 1, "code-health-10/modes-16: the Tabline ghost skips the canonical-URL de-dup stowFrontTab does")
    }

    // MARK: modes-19

    func testArchivingAnItemCanBeUndone() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        harness.nodeList.onNodeDeleted?(id)
        XCTAssertTrue(harness.window.undoManager?.canUndo == true,
                      "modes-19: onNodeDeleted archives with nothing registered on the undo manager, unlike workspace deletion")
    }

    // MARK: patterns-2

    func testDueDatePopoverClosesWhenADateIsPicked() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 20))
        window.contentView?.addSubview(anchor)
        var committed: Date??
        // C5: the editor is now a flyout beside the row; closing goes through FlyoutPanel.dismiss().
        let flyouts = ItemFlyouts()
        let editor = try XCTUnwrap(DueDateFlyout.present(in: flyouts, title: "Task", dueDate: nil, from: anchor) { committed = $0 })
        let panel = flyouts.panel(for: .dueDate)
        harness.spin(0.1)
        try XCTSkipUnless(panel.isVisible, "the flyout couldn't be shown in this test session")
        editor.saveButton.performAction()
        harness.spin(0.3)
        XCTAssertNotNil(committed, "precondition: Save committed a date")
        XCTAssertFalse(panel.isVisible,
                       "patterns-2: picking a date commits and closes the due date editor")
    }
}
