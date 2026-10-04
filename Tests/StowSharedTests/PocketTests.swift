import XCTest
@testable import StowShared

/// The pocket is every live task and snippet in a workspace, wherever it's filed. The rail
/// and the Tabline both read it, so a task inside a folder shows in both.
final class PocketTests: XCTestCase {
    private func task(_ title: String, archived: Bool = false) -> TaskItem {
        TaskItem(id: UUID(), title: title, isCompleted: false, dueDate: nil, notes: nil, createdAt: Date(), isArchived: archived)
    }

    private func snippet(_ title: String, archived: Bool = false) -> Snippet {
        Snippet(id: UUID(), title: title, content: title, language: nil, createdAt: Date(), isArchived: archived)
    }

    func testCollectsTopLevelTasksAndSnippetsInOrder() {
        let a = task("A"), b = task("B"), s = snippet("S")
        let link = Link(id: UUID(), title: "L", url: "https://l.example", faviconPath: nil)
        let pocket = Pocket.collect([.task(a), .link(link), .snippet(s), .task(b)])
        XCTAssertEqual(pocket.tasks.map(\.id), [a.id, b.id])
        XCTAssertEqual(pocket.snippets.map(\.id), [s.id])
        XCTAssertEqual(pocket.count, 3)
        XCTAssertFalse(pocket.isEmpty)
    }

    func testRecursesIntoFolders() {
        let inner = task("Inner"), deep = snippet("Deep")
        let sub = Folder(id: UUID(), name: "Sub", children: [.snippet(deep)], isExpanded: false)
        let folder = Folder(id: UUID(), name: "Inbox", children: [.task(inner), .folder(sub)], isExpanded: true)
        let pocket = Pocket.collect([.folder(folder)])
        XCTAssertEqual(pocket.tasks.map(\.id), [inner.id])
        XCTAssertEqual(pocket.snippets.map(\.id), [deep.id])
    }

    func testLeavesOutArchivedItemsAndEverythingInAnArchivedFolder() {
        let live = task("Live"), gone = task("Gone", archived: true), hidden = snippet("Hidden")
        let archivedFolder = Folder(id: UUID(), name: "Old", children: [.snippet(hidden)], isExpanded: false, isArchived: true)
        let folder = Folder(id: UUID(), name: "Inbox", children: [.task(gone), .task(live)], isExpanded: true)
        let pocket = Pocket.collect([.folder(folder), .folder(archivedFolder)])
        XCTAssertEqual(pocket.tasks.map(\.id), [live.id])
        XCTAssertTrue(pocket.snippets.isEmpty)
    }

    func testEmpty() {
        XCTAssertTrue(Pocket.collect([]).isEmpty)
    }
}
