import XCTest
import StowShared
@testable import StowIOS

/// Dragging rows on iPhone lands where the row was dropped, even with archived items in
/// between that the list doesn't show.
@MainActor
final class ListReorderTests: XCTestCase {
    private var store: TestStore!
    private var model: AppModel!

    override func setUp() async throws {
        store = TestStore(workspaces: ["Work"])
        model = AppModel(store: store.store)
    }

    override func tearDown() async throws {
        store.remove()
    }

    private func addLinks(_ titles: [String]) -> [UUID] {
        titles.map { model.addLink(urlString: "https://\($0.lowercased()).com", title: $0, parentId: nil) }
    }

    private var titles: [String] {
        model.currentWorkspace.items.map(\.displayName)
    }

    private var shown: [Node] { model.currentWorkspace.items.filter { !$0.isArchived } }

    func testMovingToTheTopWithAnArchivedItemAboveStaysBelowIt() {
        let ids = addLinks(["Archived", "Alpha", "Beta", "Gamma"])
        model.archiveNode(id: ids[0])
        // Drag Gamma to the top of the visible list.
        RowMove.apply(IndexSet(integer: 2), to: 0, shown: shown, all: model.currentWorkspace.items, parentId: nil, model: model)
        XCTAssertEqual(titles, ["Archived", "Gamma", "Alpha", "Beta"])
    }

    func testMovingDownPastAnArchivedItemLandsBeforeTheTargetRow() {
        let ids = addLinks(["Alpha", "Beta", "Archived", "Gamma", "Delta"])
        model.archiveNode(id: ids[2])
        // Visible: Alpha, Beta, Gamma, Delta. Drag Alpha into the gap before Delta.
        RowMove.apply(IndexSet(integer: 0), to: 3, shown: shown, all: model.currentWorkspace.items, parentId: nil, model: model)
        XCTAssertEqual(titles, ["Beta", "Archived", "Gamma", "Alpha", "Delta"])
    }

    func testMovingToTheEndLandsLast() {
        let ids = addLinks(["Alpha", "Beta", "Archived"])
        model.archiveNode(id: ids[2])
        RowMove.apply(IndexSet(integer: 0), to: 2, shown: shown, all: model.currentWorkspace.items, parentId: nil, model: model)
        XCTAssertEqual(titles.filter { $0 != "Archived" }, ["Beta", "Alpha"])
    }
}

/// A row redraws when what it shows changes, though `Node ==` only compares ids.
final class RowContentTests: XCTestCase {
    func testATickedTaskIsANewRow() {
        let id = UUID()
        let open = Node.task(TaskItem(id: id, title: "Call mom", isCompleted: false, dueDate: nil, notes: nil, createdAt: .distantPast))
        let done = Node.task(TaskItem(id: id, title: "Call mom", isCompleted: true, dueDate: nil, notes: nil, createdAt: .distantPast))
        XCTAssertNotEqual(NodeRowView.RowContent(node: open), NodeRowView.RowContent(node: done))
        XCTAssertEqual(NodeRowView.RowContent(node: done), NodeRowView.RowContent(node: done))
    }
}
