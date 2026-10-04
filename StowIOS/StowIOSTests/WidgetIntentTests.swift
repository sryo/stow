import XCTest
import StowShared
@testable import StowIOS

final class WidgetIntentTests: XCTestCase {
    private var testStore: TestStore!

    override func setUp() {
        testStore = TestStore(workspaces: ["Work", "Home"], selected: 1)
    }

    override func tearDown() {
        testStore.remove()
    }

    func testCurrentWorkspaceIsTheDefault() {
        XCTAssertEqual(WorkspaceEntity.defaultValue.id, WorkspaceEntity.currentID)
        XCTAssertEqual(WorkspaceEntity.defaultValue.name, "Current workspace")
    }

    func testSuggestionsListCurrentFirstThenEveryWorkspace() {
        let suggested = WorkspaceEntityQuery.suggestions(from: testStore.store.load())
        XCTAssertEqual(suggested.map(\.name), ["Current workspace", "Work", "Home"])
        XCTAssertEqual(suggested.dropFirst().map(\.id), testStore.workspaceIds.map(\.uuidString))
    }

    func testLooksUpEntitiesByIdentifier() {
        let state = testStore.store.load()
        let found = WorkspaceEntityQuery.entities(for: [testStore.workspaceIds[0].uuidString, WorkspaceEntity.currentID, "gone"], in: state)
        XCTAssertEqual(found.map(\.name), ["Work", "Current workspace"])
    }

    func testEntityMapsToAChoice() {
        XCTAssertEqual(WorkspaceEntity.defaultValue.choice, .current)
        XCTAssertEqual(WorkspaceEntity(id: testStore.workspaceIds[0].uuidString, name: "Work").choice, .workspace(testStore.workspaceIds[0]))
    }

    func testAnUnconfiguredWidgetShowsTheOpenWorkspace() {
        let content = WidgetContent.make(choice: nil, state: testStore.store.load())
        XCTAssertEqual(content.workspaceName, "Home")
    }

    func testAConfiguredWidgetShowsItsWorkspace() {
        let content = WidgetContent.make(choice: .workspace(testStore.workspaceIds[0]), state: testStore.store.load())
        XCTAssertEqual(content.workspaceName, "Work")
    }

    func testWidgetContentSkipsArchivedLinks() {
        var state = testStore.store.load()
        state.workspaces[0].items = [
            .link(StowShared.Link(id: UUID(), title: "Live", url: "https://a.com", faviconPath: nil)),
            .link(StowShared.Link(id: UUID(), title: "Old", url: "https://b.com", faviconPath: nil, isArchived: true)),
        ]
        let content = WidgetContent.make(choice: .workspace(testStore.workspaceIds[0]), state: state)
        XCTAssertEqual(content.links.map(\.title), ["Live"])
    }
}
