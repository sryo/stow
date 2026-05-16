import XCTest
@testable import StowShared

final class NodeTraversalTests: XCTestCase {

    // MARK: - Link.displayDomain

    func testDisplayDomain_stripsWwwPrefix() {
        let link = Link(id: UUID(), title: "x", url: "https://www.example.com/path", faviconPath: nil)
        XCTAssertEqual(link.displayDomain, "example.com")
    }

    func testDisplayDomain_preservesNonWwwHost() {
        let link = Link(id: UUID(), title: "x", url: "https://blog.example.com/", faviconPath: nil)
        XCTAssertEqual(link.displayDomain, "blog.example.com")
    }

    func testDisplayDomain_nilForMalformedUrl() {
        let link = Link(id: UUID(), title: "x", url: "::: not a url :::", faviconPath: nil)
        XCTAssertNil(link.displayDomain)
    }

    // MARK: - Node.flattenLinks

    func testFlattenLinks_leafLinkReturnsSelf() {
        let link = Link(id: UUID(), title: "x", url: "https://x", faviconPath: nil)
        let result = Node.link(link).flattenLinks()
        XCTAssertEqual(result.map(\.id), [link.id])
    }

    func testFlattenLinks_emptyForTaskOrSnippet() {
        let task = TaskItem(id: UUID(), title: "t", isCompleted: false, dueDate: nil, notes: nil, createdAt: Date())
        let snippet = Snippet(id: UUID(), title: "s", content: "", language: nil, createdAt: Date())
        XCTAssertTrue(Node.task(task).flattenLinks().isEmpty)
        XCTAssertTrue(Node.snippet(snippet).flattenLinks().isEmpty)
    }

    func testFlattenLinks_recursesIntoNestedFolders() {
        let l1 = Link(id: UUID(), title: "a", url: "https://a", faviconPath: nil)
        let l2 = Link(id: UUID(), title: "b", url: "https://b", faviconPath: nil)
        let inner = Folder(id: UUID(), name: "inner", children: [.link(l2)], isExpanded: true)
        let outer = Folder(id: UUID(), name: "outer", children: [.link(l1), .folder(inner)], isExpanded: true)
        let result = Node.folder(outer).flattenLinks().map(\.id)
        XCTAssertEqual(result, [l1.id, l2.id])
    }

    func testFlattenLinks_onSequenceFlattensAllRoots() {
        let l1 = Link(id: UUID(), title: "a", url: "https://a", faviconPath: nil)
        let l2 = Link(id: UUID(), title: "b", url: "https://b", faviconPath: nil)
        let nodes: [Node] = [.link(l1), .link(l2)]
        XCTAssertEqual(nodes.flattenLinks().map(\.id), [l1.id, l2.id])
    }

    // MARK: - Node.flattenIds

    func testFlattenIds_includesSelf() {
        let l = Link(id: UUID(), title: "x", url: "https://x", faviconPath: nil)
        XCTAssertEqual(Node.link(l).flattenIds(), [l.id])
    }

    func testFlattenIds_folderIncludesItselfAndDescendantsInPreOrder() {
        let l1 = Link(id: UUID(), title: "a", url: "https://a", faviconPath: nil)
        let l2 = Link(id: UUID(), title: "b", url: "https://b", faviconPath: nil)
        let inner = Folder(id: UUID(), name: "inner", children: [.link(l2)], isExpanded: true)
        let outer = Folder(id: UUID(), name: "outer", children: [.link(l1), .folder(inner)], isExpanded: true)
        XCTAssertEqual(Node.folder(outer).flattenIds(), [outer.id, l1.id, inner.id, l2.id])
    }

    // MARK: - Array<Workspace> lookup

    func testWorkspaceLookup_byIdAndIndex() {
        let a = Workspace(id: UUID(), name: "A", colorId: .defaultColor(), items: [])
        let b = Workspace(id: UUID(), name: "B", colorId: .defaultColor(), items: [])
        let list = [a, b]
        XCTAssertEqual(list.first(id: b.id)?.name, "B")
        XCTAssertEqual(list.firstIndex(id: b.id), 1)
        XCTAssertNil(list.first(id: UUID()))
        XCTAssertNil(list.firstIndex(id: UUID()))
    }
}
