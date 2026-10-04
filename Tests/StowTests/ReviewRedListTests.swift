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
        TablineController.shared.onStowURL?(URL(string: "https://stow.invalid/new")!, "New")
        guard case .link(let first)? = model.currentWorkspace.items.first else { return XCTFail("no items") }
        XCTAssertEqual(first.url, "https://stow.invalid/new",
                       "code-health-10/modes-16: the Tabline ghost appends at the bottom; stowFrontTab inserts at index 0")
    }

    func testStowingTheSameTabTwiceFromTheTablineKeepsOneLink() {
        harness.host(width: 400)
        let url = URL(string: "https://stow.invalid/same")!
        TablineController.shared.onStowURL?(url, "Same")
        TablineController.shared.onStowURL?(url, "Same")
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
        let editor = DueDatePopoverController(dueDate: nil) { committed = $0 }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = editor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        harness.spin(0.1)
        try XCTSkipUnless(popover.isShown, "the popover couldn't be shown in this test session")
        let save = editor.view.descendants(of: NSButton.self).first { $0.title == "Save" }
        save?.performClick(nil)
        harness.spin(0.3)
        XCTAssertNotNil(committed, "precondition: Save committed a date")
        XCTAssertFalse(popover.isShown,
                       "patterns-2: DueDatePopoverController closes itself with dismiss(nil), which does nothing for an NSPopover it wasn't presented by")
    }

    // MARK: patterns-11

    func testSettingsPageRowShowsTheWorkspacesChosenIcon() {
        func render(_ icon: WorkspaceIcon) -> Data? {
            let workspace = Workspace(id: UUID(), name: "Home", colorId: .ocean, items: [], icon: icon)
            let content = WorkspaceRowView.Content(name: workspace.name, colorId: workspace.colorId,
                                                   iconLinks: WorkspaceIconSites.pick(from: workspace.items), opensIn: nil,
                                                   itemCount: 0, position: 1, total: 1, canDelete: false)
            let item = WorkspaceCollectionViewItem()
            item.loadView()
            item.view.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
            item.view.appearance = NSAppearance(named: .aqua)
            item.configure(workspace: workspace, content: content, actions: .init(
                showMenu: { _, _ in }, showColorMenu: { _, _ in }, showProfileMenu: { _, _ in },
                rename: { _ in }, commitRename: { _, _ in }, finishRename: { _ in }, delete: { _ in }, move: { _, _ in }))
            item.view.layoutSubtreeIfNeeded()
            guard let rep = item.view.bitmapImageRepForCachingDisplay(in: item.view.bounds) else { return nil }
            item.view.cacheDisplay(in: item.view.bounds, to: rep)
            return rep.tiffRepresentation
        }
        let favicons = render(.favicons)
        let symbol = render(.symbol("star"))
        XCTAssertNotNil(favicons)
        XCTAssertNotEqual(favicons, symbol,
                          "patterns-11: WorkspaceRowView draws the same icon for .favicons and .symbol(\"star\"); Workspace.icon is never read")
    }
}
