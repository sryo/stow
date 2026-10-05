import AppKit
import XCTest
@testable import StowCore
import StowShared

/// ⌥↩ means "Open all" everywhere: on a list folder it opens the folder's links, on a
/// list link it opens a fresh tab (as ⌥-click does), and in a flyout it runs the Open all
/// button. Row actions are on ⌃↩ and ⇧F10, the standard context-menu keys.
@MainActor
final class OptionReturnTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() {
        super.setUp()
        harness = RedHarness()
    }

    override func tearDown() {
        harness.tearDown()
        super.tearDown()
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private struct Calls {
        var openedFolders: [UUID] = []
        var newTabLinks: [UUID] = []
        var selected: [UUID] = []
        var rowActions: [Int] = []
    }

    private enum Target { case folder, link }

    /// A list with a folder (holding a link) and a link, the cursor on `target`, and
    /// every outcome recorded.
    private func list(cursorOn target: Target) -> (NodeListViewController, () -> Calls, folder: UUID, link: UUID) {
        let link = harness.model.addLink(urlString: "https://b.example", title: "B", parentId: nil)
        let folder = harness.model.addFolder(name: "Refs", parentId: nil, isExpanded: false)
        _ = harness.model.addLink(urlString: "https://a.example", title: "A", parentId: folder)
        harness.host(width: 400)
        let list = harness.nodeList
        var calls = Calls()
        list.onOpenFolderLinks = { calls.openedFolders.append($0) }
        list.onOpenLinkInNewTab = { calls.newTabLinks.append($0) }
        list.onNodeSelected = { calls.selected.append($0) }
        list.rowActionsPresenter = { calls.rowActions.append($0) }
        _ = list.handleListKey(key(125)) // reveals the cursor on the first row
        let id = target == .folder ? folder : link
        for _ in 0..<10 where list.keyboardCursorId != id { _ = list.handleListKey(key(125)) }
        XCTAssertEqual(list.keyboardCursorId, id, "precondition: the cursor reached the \(target) row")
        return (list, { calls }, folder, link)
    }

    private func rowIndex(of id: UUID, in list: NodeListViewController) -> Int? {
        (0..<20).first { list.visibleNode(at: $0)?.id == id }
    }

    func testOptionReturnOnAFolderOpensAllItsLinks() {
        let (list, calls, folder, _) = list(cursorOn: .folder)
        XCTAssertTrue(list.handleListKey(key(36, .option)))
        XCTAssertEqual(calls().openedFolders, [folder])
        XCTAssertTrue(calls().rowActions.isEmpty, "⌥↩ still opened the row actions")
    }

    func testOptionReturnOnALinkOpensItInANewTab() {
        let (list, calls, _, link) = list(cursorOn: .link)
        XCTAssertTrue(list.handleListKey(key(76, .option)))
        XCTAssertEqual(calls().newTabLinks, [link])
        XCTAssertTrue(calls().rowActions.isEmpty)
    }

    func testControlReturnShowsTheRowActions() {
        let (list, calls, _, link) = list(cursorOn: .link)
        XCTAssertTrue(list.handleListKey(key(36, .control)))
        XCTAssertEqual(calls().rowActions, [rowIndex(of: link, in: list)!])
        XCTAssertTrue(calls().openedFolders.isEmpty && calls().newTabLinks.isEmpty)
    }

    func testShiftF10ShowsTheRowActions() {
        let (list, calls, folder, _) = list(cursorOn: .folder)
        XCTAssertTrue(list.handleListKey(key(109, [.shift, .function])))
        XCTAssertEqual(calls().rowActions, [rowIndex(of: folder, in: list)!])
    }

    // MARK: Flyouts

    func testOptionReturnInAFlyoutRunsOpenAll() {
        var ran: [String] = []
        let list = FlyoutListView(title: "Refs", rows: [], footer: [
            .init(title: "Edit…") { ran.append("edit") },
            .openAll { ran.append("open all") },
        ])
        list.insertNewlineIgnoringFieldEditor(nil)
        XCTAssertEqual(ran, ["open all"])
    }

    func testOptionReturnInAFlyoutWithoutOpenAllDoesNothing() {
        var ran: [String] = []
        let list = FlyoutListView(title: "Workspaces", rows: [], footer: WorkspaceListFlyout.footer(edit: { ran.append("edit") }, newWorkspace: { ran.append("new") }))
        list.insertNewlineIgnoringFieldEditor(nil)
        XCTAssertEqual(ran, [], "⌥↩ in the workspace list opened the editor")
    }

    func testTheOpenAllButtonNamesItsKey() {
        XCTAssertEqual(FlyoutListView.FooterButton.openAll {}.title, "Open all  ⌥↩")
    }

    // MARK: Help text

    func testAllShortcutsListsBothKeys() {
        let rows = AllShortcuts.listKeys
        XCTAssertEqual(rows.first { $0.title == "Row actions" }?.keys, "⌃↩  ⇧F10")
        XCTAssertEqual(rows.first { $0.keys == "⌥↩" }?.title, "Open all, or in a new tab")
    }

    func testTheFolderMenuShowsOpenAllsKey() {
        let folder = harness.model.addFolder(name: "Refs", parentId: nil)
        _ = harness.model.addLink(urlString: "https://a.example", title: "A", parentId: folder)
        guard let node = harness.model.nodeById(folder) else { return XCTFail("no folder") }
        let item = NodeMenu.make(for: node, model: harness.model, actions: .init()).items.first { $0.title == "Open all links" }
        XCTAssertEqual(item?.keyEquivalent, "\r")
        XCTAssertEqual(item?.keyEquivalentModifierMask, .option)
    }
}
