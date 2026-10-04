import AppKit
import XCTest
@testable import StowCore
import StowShared

/// B6 and C16: the one item menu (list row, mosaic tile, rail cell) and the one
/// "New…" menu (title-bar +, empty state, list background).
@MainActor
final class NodeMenuTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    private func fire(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("no item to fire") }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: NodeMenu

    func testALinkMenuCopiesItsLink() {
        let id = model.addLink(urlString: "https://example.com/a", title: "A", parentId: nil)
        guard let node = model.nodeById(id) else { return XCTFail("no node") }
        let board = NSPasteboard(name: .init("stow-node-menu-\(UUID().uuidString)"))
        var actions = NodeMenu.Actions()
        actions.pasteboard = board
        let menu = NodeMenu.make(for: node, model: model, actions: actions)
        XCTAssertTrue(titles(menu).contains("Copy link"), "B6 / modes-22: a link's menu has Copy link; it's \(titles(menu))")
        fire(menu.items.first { $0.title == "Copy link" })
        XCTAssertEqual(board.string(forType: .string), "https://example.com/a")
    }

    func testEveryKindCanBeRenamedMovedAndArchived() {
        let ids = [
            model.addLink(urlString: "https://example.com", title: "Link", parentId: nil),
            model.addFolder(name: "Folder", parentId: nil),
            model.addTask(title: "Task", parentId: nil),
            model.addSnippet(title: "Snippet", content: "x", language: nil, parentId: nil),
        ]
        for id in ids {
            guard let node = model.nodeById(id) else { return XCTFail("no node") }
            let t = titles(NodeMenu.make(for: node, model: model, actions: .init()))
            XCTAssertTrue(t.contains("Rename…") && t.contains("Move to") && t.contains("Archive"), "\(node.displayName): \(t)")
        }
    }

    func testTheMenuRunsItsActionsAfterTheBuilderIsGone() {
        let id = model.addTask(title: "Task", parentId: nil)
        var archived: UUID?
        var renamed: UUID?
        var actions = NodeMenu.Actions()
        actions.archive = { archived = $0 }
        actions.rename = { renamed = $0 }
        let menu = NodeMenu.make(for: model.nodeById(id)!, model: model, actions: actions)
        fire(menu.items.first { $0.title == "Archive" })
        fire(menu.items.first { $0.title == "Rename…" })
        fire(menu.items.first { $0.title == "Mark complete" })
        XCTAssertEqual(archived, id)
        XCTAssertEqual(renamed, id)
        guard case .task(let task)? = model.nodeById(id) else { return XCTFail("no task") }
        XCTAssertTrue(task.isCompleted)
    }

    func testMoveToListsTheOtherWorkspacesAndMovesThere() {
        let home = model.currentWorkspace.id
        let other = model.createWorkspace(name: "Other")
        model.selectWorkspace(id: home)
        let id = model.addLink(urlString: "https://example.com", title: "Link", parentId: nil)
        let menu = NodeMenu.make(for: model.nodeById(id)!, model: model, actions: .init())
        let move = menu.items.first { $0.title == "Move to" }?.submenu
        let names = move.map(titles) ?? []
        XCTAssertTrue(names.contains("Other"))
        XCTAssertFalse(names.contains(model.workspaces.first { $0.id == home }!.name), "the item's own workspace isn't offered")
        fire(move?.items.first { $0.title == "Other" })
        XCTAssertTrue(model.workspaces.first { $0.id == other }!.items.contains { $0.id == id })
    }

    func testTheListAndTheMosaicUseTheNodeMenu() {
        let id = model.addLink(urlString: "https://example.com", title: "Link", parentId: nil)
        for width in [400.0, 700.0] {
            harness.host(width: width)
            let list = harness.nodeList
            guard let index = (0..<20).first(where: { list.visibleNode(at: $0)?.id == id }) else { return XCTFail("no row") }
            let menu = list.contextMenu(at: IndexPath(item: index, section: 0))
            XCTAssertTrue(menu.map(titles)?.contains("Copy link") == true, "width \(width): \(menu.map(titles) ?? [])")
        }
    }

    func testTheRailNodeMenuIsTheNodeMenu() {
        let id = model.addLink(urlString: "https://example.com", title: "Link", parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        XCTAssertTrue(harness.controller.nodeMenu(for: model.nodeById(id)!).map(titles)?.contains("Copy link") == true)
    }

    // MARK: NewItemMenu

    private final class Target: NSObject, NewItemMenuTarget {
        var picked: [String] = []
        func newFolderFromMenu(_ sender: Any?) { picked.append("folder") }
        func newTaskFromMenu(_ sender: Any?) { picked.append("task") }
        func newSnippetFromMenu(_ sender: Any?) { picked.append("snippet") }
        func newWorkspaceFromMenu(_ sender: Any?) { picked.append("workspace") }
        func pasteFromMenu(_ sender: Any?) { picked.append("paste") }
        func importFromArcFromMenu(_ sender: Any?) { picked.append("arc") }
    }

    func testNewItemMenuIsInSentenceCaseWithTheMenuBarsKeys() {
        let target = Target()
        let menu = NewItemMenu.make(includePaste: false, includeImport: false, target: target)
        XCTAssertEqual(titles(menu), ["New folder…", "New task…", "New snippet…", "New workspace…"])
        let folder = menu.items.first { $0.title == "New folder…" }
        XCTAssertEqual(folder?.keyEquivalent.lowercased(), "n")
        XCTAssertEqual(folder?.keyEquivalentModifierMask, [.command, .shift])
        let workspace = menu.items.first { $0.title == "New workspace…" }
        XCTAssertEqual(workspace?.keyEquivalent, "n")
        XCTAssertEqual(workspace?.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil }, "every entry has a symbol")
        for item in menu.items where !item.isSeparatorItem { fire(item) }
        XCTAssertEqual(target.picked, ["folder", "task", "snippet", "workspace"])
    }

    func testNewItemMenuCanLeadWithPasteAndImport() {
        let target = Target()
        let menu = NewItemMenu.make(includePaste: true, includeImport: true, target: target, pasteEnabled: false)
        XCTAssertEqual(Array(titles(menu).prefix(2)), ["Paste", "Import from Arc…"])
        XCTAssertFalse(menu.items[0].isEnabled)
    }

    func testTheListBackgroundUsesTheNewItemMenu() {
        _ = model.addLink(urlString: "https://example.com", title: "Link", parentId: nil)
        harness.host(width: 400)
        let menu = harness.nodeList.contextMenu(at: nil)
        XCTAssertEqual(menu.map(titles), ["New folder…", "New task…", "New snippet…", "New workspace…"])
    }
}
