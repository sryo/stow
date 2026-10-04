import XCTest
@testable import StowShared

/// `Node ==` compares ids only, so a list that diffs rows with it never sees a ticked task
/// or an opened folder. `hasSameContent(as:)` compares what a row shows, at any depth.
final class NodeContentTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 0)

    private func task(_ id: UUID, done: Bool) -> Node {
        .task(TaskItem(id: id, title: "Book flights", isCompleted: done, dueDate: nil, notes: nil, createdAt: date))
    }

    func testATickedTaskIsTheSameNodeButNotTheSameContent() {
        let id = UUID()
        XCTAssertEqual(task(id, done: false), task(id, done: true), "precondition: Node == compares ids")
        XCTAssertFalse(task(id, done: false).hasSameContent(as: task(id, done: true)))
        XCTAssertTrue(task(id, done: true).hasSameContent(as: task(id, done: true)))
    }

    func testAnOpenedFolderOrAChangedChildChangesTheFolder() {
        let folderId = UUID(), childId = UUID()
        func folder(expanded: Bool, childDone: Bool) -> Node {
            .folder(Folder(id: folderId, name: "Trips", children: [task(childId, done: childDone)], isExpanded: expanded))
        }
        XCTAssertFalse(folder(expanded: false, childDone: false).hasSameContent(as: folder(expanded: true, childDone: false)))
        XCTAssertFalse(folder(expanded: true, childDone: false).hasSameContent(as: folder(expanded: true, childDone: true)))
        XCTAssertTrue(folder(expanded: true, childDone: true).hasSameContent(as: folder(expanded: true, childDone: true)))
    }

    func testDifferentKindsOrIdsNeverMatch() {
        let id = UUID()
        let link = Node.link(Link(id: id, title: "Book flights", url: "https://example.com", faviconPath: nil))
        XCTAssertFalse(link.hasSameContent(as: task(id, done: false)))
        XCTAssertFalse(task(UUID(), done: false).hasSameContent(as: task(UUID(), done: false)))
    }
}
