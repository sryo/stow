import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Group 4B: rename and jump letters on mosaic tiles (B7, G4), text dropped from a browser
/// (G1), items dropped on workspace tabs (G2) and the empty rail's drop cell (G5).
@MainActor
final class DropAndHintTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.controller?.itemFlyouts.closeAll()
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func visibleItems<T: NSCollectionViewItem>(_ type: T.Type) -> [(Int, T)] {
        guard let collection = harness.nodeList.view.descendants(of: NSCollectionView.self).first else { return [] }
        return collection.visibleItems().compactMap { item in
            guard let typed = item as? T, let path = collection.indexPath(for: item) else { return nil }
            return (path.item, typed)
        }.sorted { $0.0 < $1.0 }
    }

    // MARK: B7 rename in the mosaic

    func testF2OnAMosaicTileRenamesInAFlyoutAndEndsTheRename() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Old", parentId: nil)
        harness.host(width: 900)
        harness.window.orderFront(nil)
        let flyout = try XCTUnwrap(harness.nodeList.beginRename(for: id), "no rename flyout on a tile")
        XCTAssertEqual(harness.nodeList.inlineRenameNodeId, id)
        XCTAssertTrue(harness.controller.itemFlyouts.isOpen(.text))
        flyout.field.stringValue = "New"
        flyout.saveButton.performAction()
        XCTAssertEqual(model.nodeById(id)?.displayName, "New")
        XCTAssertNil(harness.nodeList.inlineRenameNodeId, "saving left the list renaming")
    }

    func testEscOnAMosaicRenameFlyoutKeepsTheNameAndEndsTheRename() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Old", parentId: nil)
        harness.host(width: 900)
        harness.window.orderFront(nil)
        let flyout = try XCTUnwrap(harness.nodeList.beginRename(for: id))
        flyout.field.stringValue = "Typed"
        _ = flyout.control(flyout.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(model.nodeById(id)?.displayName, "Old")
        XCTAssertNil(harness.nodeList.inlineRenameNodeId)
    }

    func testAFolderGroupHeaderInTheMosaicRenames() {
        let folder = model.addFolder(name: "Reading", parentId: nil, isExpanded: true)
        _ = model.addLink(urlString: "https://example.com", title: "Inside", parentId: folder)
        harness.host(width: 900)
        harness.window.orderFront(nil)
        XCTAssertNotNil(harness.nodeList.beginRename(for: folder), "no rename flyout on a group header")
        XCTAssertEqual(harness.nodeList.inlineRenameNodeId, folder)
    }

    func testAFlyoutRenameReplacedByAnotherFlyoutNoLongerCountsAsRenaming() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Old", parentId: nil)
        harness.host(width: 900)
        harness.window.orderFront(nil)
        _ = try XCTUnwrap(harness.nodeList.beginRename(for: id))
        harness.nodeList.presentEditURLFlyout(for: id)
        XCTAssertNil(harness.nodeList.inlineRenameNodeId, "a replaced rename flyout would block list reloads and keys")
    }

    func testAPendingRenameThatFindsNoRowIsDropped() {
        let id = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: 400)
        harness.nodeList.scheduleInlineRename(for: id)
        // A reload without the item (filtered out, say) can't honour the rename...
        harness.nodeList.reloadData(with: [], forceExpand: false)
        harness.spin(0.1)
        // ...and a later one mustn't start it out of nowhere.
        harness.nodeList.reloadData(with: model.currentWorkspace.items, forceExpand: false)
        harness.spin(0.2)
        XCTAssertNil(harness.nodeList.inlineRenameNodeId)
    }

    // MARK: G4 jump letters on tiles

    func testJumpModeDrawsLettersOnMosaicTiles() {
        for i in 0..<3 { _ = model.addLink(urlString: "https://site\(i).example", title: "Site \(i)", parentId: nil) }
        harness.host(width: 900)
        harness.nodeList.isJumpModeActive = true
        let hints = visibleItems(NodeTileItem.self).map(\.1.hintCharacter)
        XCTAssertEqual(hints, ["a", "b", "c"])
        harness.nodeList.isJumpModeActive = false
        XCTAssertEqual(visibleItems(NodeTileItem.self).map(\.1.hintCharacter), [nil, nil, nil])
    }

    func testTilesConfiguredWhileInJumpModeShowTheirLetters() {
        for i in 0..<2 { _ = model.addLink(urlString: "https://site\(i).example", title: "Site \(i)", parentId: nil) }
        harness.host(width: 900)
        harness.nodeList.isJumpModeActive = true
        harness.nodeList.reconfigureVisibleItems()
        XCTAssertEqual(visibleItems(NodeTileItem.self).map(\.1.hintCharacter), ["a", "b"])
    }

    func testRowsAndTilesShareOneItemProtocol() {
        XCTAssertTrue((NodeTileItem() as Any) is NodeItemConfigurable)
        XCTAssertTrue((NodeCollectionViewItem() as Any) is NodeItemConfigurable)
    }

    // MARK: G1 text from the browser

    func testDroppedTextReadsURLsBeforePlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("stow-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/a")! as NSURL])
        XCTAssertEqual(EmptyStateView.droppedText(from: pasteboard), "https://example.com/a")
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(EmptyStateView.droppedText(from: pasteboard), "hello")
    }

    func testTextDroppedBetweenRowsLandsAtThatIndex() {
        _ = model.addLink(urlString: "https://a.example", title: "A", parentId: nil)
        let b = model.addLink(urlString: "https://b.example", title: "B", parentId: nil)
        harness.host(width: 400)
        let list = harness.nodeList
        guard let bRow = (0..<10).first(where: { list.visibleNode(at: $0)?.id == b }) else { return XCTFail("no row for B") }
        let target = list.dropDestination(at: IndexPath(item: bRow, section: 0), operation: .before)
        XCTAssertNil(target.parentId)
        XCTAssertEqual(target.index, model.currentWorkspace.items.firstIndex { $0.id == b })
    }

    func testTextDroppedOnAFolderGoesInside() {
        let folder = model.addFolder(name: "Reading", parentId: nil, isExpanded: true)
        _ = model.addLink(urlString: "https://a.example", title: "A", parentId: folder)
        harness.host(width: 400)
        let list = harness.nodeList
        guard let row = (0..<10).first(where: { list.visibleNode(at: $0)?.id == folder }) else { return XCTFail("no folder row") }
        let target = list.dropDestination(at: IndexPath(item: row, section: 0), operation: .on)
        XCTAssertEqual(target.parentId, folder)
        XCTAssertEqual(target.index, 1)
    }

    func testTheRailRegistersTextDrops() {
        let rail = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        XCTAssertTrue(rail.registeredDraggedTypes.contains(.string))
    }

    // MARK: G2 items dropped on workspace tabs

    func testATabUnderThePointerIsTheDropTargetButTheCurrentOneIsNot() {
        let a = UUID(), b = UUID()
        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        strip.workspaces = [.init(id: a, name: "A", colorId: .ocean), .init(id: b, name: "B", colorId: .moss)]
        strip.selectedWorkspaceId = a
        strip.layoutSubtreeIfNeeded()
        guard let aFrame = strip.tabFrame(for: a), let bFrame = strip.tabFrame(for: b) else { return XCTFail("no tabs") }
        XCTAssertEqual(strip.dropTarget(at: NSPoint(x: bFrame.midX, y: bFrame.midY)), b)
        XCTAssertNil(strip.dropTarget(at: NSPoint(x: aFrame.midX, y: aFrame.midY)))
        XCTAssertNil(strip.dropTarget(at: NSPoint(x: bFrame.maxX + 200, y: bFrame.midY)))
    }

    func testAnItemDragEndingAnywhereShowsTheSourceRowAgain() {
        _ = model.addLink(urlString: "https://a.example", title: "A", parentId: nil)
        harness.host(width: 400)
        guard let (_, item) = visibleItems(NodeCollectionViewItem.self).first else { return XCTFail("no row") }
        item.view.isHidden = true
        item.view.alphaValue = 0
        harness.nodeList.restoreDraggedItems()
        XCTAssertFalse(item.view.isHidden)
        XCTAssertEqual(item.view.alphaValue, 1)
    }

    // MARK: G5 the empty rail

    func testAnEmptyWorkspaceInTheRailShowsADropCellWithTheEmptyStateTip() {
        let rail = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        rail.configure(workspaces: [RailView.WorkspaceEntry(id: UUID(), name: "Alpha", colorId: .ocean)],
                       selectedId: nil, colorId: .defaultColor(), items: [])
        var dot = RailView.WorkspaceEntry(id: UUID(), name: "Alpha", colorId: .ocean)
        rail.configure(workspaces: [dot], selectedId: dot.id, colorId: .defaultColor(), items: [])
        let cells = rail.descendants(of: RailCell.self)
        XCTAssertEqual(cells.count, 1)
        guard let cell = cells.first, case .empty = cell.kind else { return XCTFail("no empty cell") }
        let copy = EmptyStateCopy.make(.emptyWorkspace, workspaceName: "Alpha", isTouch: false)
        XCTAssertEqual(cell.tip.title, copy?.title)
        XCTAssertEqual(cell.tip.detail, copy?.message)
        // Items make it go away.
        dot = RailView.WorkspaceEntry(id: dot.id, name: "Alpha", colorId: .ocean)
        let link = Link(id: UUID(), title: "GitHub", url: "https://github.com", faviconPath: nil)
        rail.configure(workspaces: [dot], selectedId: dot.id, colorId: .defaultColor(), items: [.link(link)])
        XCTAssertFalse(rail.descendants(of: RailCell.self).contains { if case .empty = $0.kind { return true }; return false })
    }
}
