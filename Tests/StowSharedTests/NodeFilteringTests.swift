import XCTest
@testable import StowShared

final class NodeFilteringTests: XCTestCase {

    private func makeTask(_ title: String, notes: String? = nil, archived: Bool = false) -> Node {
        var task = TaskItem(id: UUID(), title: title, isCompleted: false, dueDate: nil, notes: notes, createdAt: Date())
        task.isArchived = archived
        return .task(task)
    }

    private func makeSnippet(_ title: String, content: String, archived: Bool = false) -> Node {
        var snippet = Snippet(id: UUID(), title: title, content: content, language: nil, createdAt: Date())
        snippet.isArchived = archived
        return .snippet(snippet)
    }

    private func makeLink(_ title: String, url: String = "https://x.test", archived: Bool = false) -> Node {
        var link = Link(id: UUID(), title: title, url: url, faviconPath: nil)
        link.isArchived = archived
        return .link(link)
    }

    // MARK: - Task

    func testTaskTitleMatch() {
        let result = NodeFiltering.filter(nodes: [makeTask("Buy milk")], query: "milk")
        XCTAssertEqual(result.count, 1)
    }

    func testTaskNotesMatch_caseInsensitive() {
        let result = NodeFiltering.filter(nodes: [makeTask("Plan", notes: "Call DENTIST")], query: "dentist")
        XCTAssertEqual(result.count, 1)
    }

    func testTaskWithNilNotesAndNoTitleMatchExcluded() {
        let result = NodeFiltering.filter(nodes: [makeTask("Buy milk", notes: nil)], query: "dentist")
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - Snippet

    func testSnippetTitleMatch() {
        let result = NodeFiltering.filter(nodes: [makeSnippet("Curl example", content: "...")], query: "curl")
        XCTAssertEqual(result.count, 1)
    }

    func testSnippetContentMatch_caseInsensitive() {
        let result = NodeFiltering.filter(nodes: [makeSnippet("Notes", content: "SELECT * FROM users")], query: "select")
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Archive

    func testArchivedNodesHidden() {
        let nodes = [
            makeTask("visible task"),
            makeTask("archived task", archived: true)
        ]
        let result = NodeFiltering.filter(nodes: nodes, query: "task")
        XCTAssertEqual(result.count, 1)
        if case .task(let t) = result[0] {
            XCTAssertEqual(t.title, "visible task")
        }
    }

    // MARK: - Folder surfacing

    func testFolderSurfacesWhenChildMatches() {
        let folder = Folder(
            id: UUID(),
            name: "container",
            children: [makeTask("widget assembly")],
            isExpanded: false
        )
        let result = NodeFiltering.filter(nodes: [.folder(folder)], query: "widget")
        XCTAssertEqual(result.count, 1)
        guard case .folder(let surfaced) = result[0] else {
            XCTFail("Expected folder"); return
        }
        XCTAssertTrue(surfaced.isExpanded, "Surfaced folder should expand to reveal the match")
        XCTAssertEqual(surfaced.children.count, 1)
    }

    func testFolderHiddenWhenNoChildMatches() {
        let folder = Folder(
            id: UUID(),
            name: "container",
            children: [makeTask("widget")],
            isExpanded: false
        )
        let result = NodeFiltering.filter(nodes: [.folder(folder)], query: "gadget")
        XCTAssertEqual(result.count, 0, "Folder name itself isn't matched — only its descendants")
    }

    // MARK: - Edge

    func testEmptyQueryMatchesNothing() {
        // Swift's String.contains("") returns false, so empty query filters every
        // node out. Callers (SearchCoordinator) should short-circuit before
        // invoking filter when the query is empty; this test pins the contract.
        let nodes = [makeTask("a"), makeLink("c"), makeSnippet("d", content: "")]
        let result = NodeFiltering.filter(nodes: nodes, query: "")
        XCTAssertEqual(result.count, 0)
    }
}
