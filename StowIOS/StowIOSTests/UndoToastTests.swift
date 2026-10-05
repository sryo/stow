import XCTest
import StowShared
@testable import StowIOS

/// Archive, delete and bulk archive show an Undo toast for a few seconds, like the Mac's.
@MainActor
final class UndoToastTests: XCTestCase {
    private var testStore: TestStore!
    private var model: AppModel!
    private var toasts: UndoToastCenter!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home"], selected: 0)
        model = AppModel(store: testStore.store)
        toasts = UndoToastCenter()
    }

    override func tearDown() async throws {
        testStore.remove()
    }

    private func addLink(_ title: String) -> UUID {
        model.addLink(urlString: "https://\(title.lowercased()).com", title: title, parentId: nil)
    }

    func testTheToastStaysAFewSecondsLikeTheMacs() {
        XCTAssertEqual(UndoToastCenter.duration, 6)
    }

    func testArchivingOneItemOffersUndo() {
        let id = addLink("GitHub")
        XCTAssertTrue(ItemUndo.archive([id], model: model, toasts: toasts, undoManager: nil))
        XCTAssertEqual(model.nodeById(id)?.isArchived, true)
        XCTAssertEqual(toasts.current?.message, "Archived “GitHub”")
        toasts.undo()
        XCTAssertEqual(model.nodeById(id)?.isArchived, false)
        XCTAssertNil(toasts.current)
    }

    func testBulkArchiveOffersOneUndoForAll() {
        let ids = [addLink("GitHub"), addLink("Swift"), addLink("Figma")]
        ItemUndo.archive(ids, model: model, toasts: toasts, undoManager: nil)
        XCTAssertEqual(toasts.current?.message, "Archived 3 items")
        XCTAssertTrue(ids.allSatisfy { model.nodeById($0)?.isArchived == true })
        toasts.undo()
        XCTAssertTrue(ids.allSatisfy { model.nodeById($0)?.isArchived == false })
    }

    func testArchivingWhatsArchivedAlreadyOffersNothing() {
        let id = addLink("GitHub")
        model.archiveNode(id: id)
        XCTAssertFalse(ItemUndo.archive([id], model: model, toasts: toasts, undoManager: nil))
        XCTAssertNil(toasts.current)
    }

    func testDeletingForGoodOffersUndo() {
        let id = addLink("GitHub")
        model.archiveNode(id: id)
        XCTAssertTrue(ItemUndo.deletePermanently(id, model: model, toasts: toasts, undoManager: nil))
        XCTAssertNil(model.nodeById(id))
        XCTAssertEqual(toasts.current?.message, "Deleted “GitHub”")
        toasts.undo()
        XCTAssertNotNil(model.nodeById(id))
    }

    func testShakeStillUndoesAndClosesTheToast() {
        let id = addLink("GitHub")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        ItemUndo.archive([id], model: model, toasts: toasts, undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(undoManager.undoActionName, "Archive")
        undoManager.undo()
        XCTAssertEqual(model.nodeById(id)?.isArchived, false)
        XCTAssertNil(toasts.current)
    }

    func testTheToastsUndoClearsTheShakeEntry() {
        let id = addLink("GitHub")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        ItemUndo.archive([id], model: model, toasts: toasts, undoManager: undoManager)
        undoManager.endUndoGrouping()
        toasts.undo()
        XCTAssertFalse(undoManager.canUndo, "a second undo by shake would archive nothing")
    }

    func testTheToastGoesAwayOnItsOwn() async throws {
        let id = addLink("GitHub")
        let quick = UndoToastCenter(duration: 0.05)
        ItemUndo.archive([id], model: model, toasts: quick, undoManager: nil)
        XCTAssertNotNil(quick.current)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(quick.current)
        XCTAssertEqual(model.nodeById(id)?.isArchived, true, "timing out keeps the change")
    }

    func testAnOlderToastsTimerDoesntCloseANewerOne() async throws {
        let quick = UndoToastCenter(duration: 0.2)
        ItemUndo.archive([addLink("GitHub")], model: model, toasts: quick, undoManager: nil)
        try await Task.sleep(for: .milliseconds(120))
        ItemUndo.archive([addLink("Swift")], model: model, toasts: quick, undoManager: nil)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(quick.current?.message, "Archived “Swift”")
    }
}

/// Widget link tiles go through stow://open, like the Live Activity's, and select the
/// widget's workspace on the way.
@MainActor
final class WidgetLinkTests: XCTestCase {
    private var testStore: TestStore!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home"], selected: 0)
    }

    override func tearDown() async throws {
        testStore.remove()
    }

    func testAWidgetTileOpensThroughStow() throws {
        let home = testStore.workspaceIds[1]
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "https://github.com/sryo", workspace: home))
        XCTAssertEqual(url.scheme, "stow")
        XCTAssertEqual(url.host, "open")
        XCTAssertEqual(StowActivityAttributes.target(ofDeepLink: url)?.absoluteString, "https://github.com/sryo")
        XCTAssertEqual(StowActivityAttributes.workspace(ofDeepLink: url), home)
    }

    func testABareHostGetsHTTPSLikeTheRows() throws {
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "github.com"))
        XCTAssertEqual(StowActivityAttributes.target(ofDeepLink: url)?.absoluteString, "https://github.com")
    }

    func testTheLiveActivitysLinksStillWork() throws {
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "https://example.com/a?b=c&d=e"))
        XCTAssertEqual(StowActivityAttributes.target(ofDeepLink: url)?.absoluteString, "https://example.com/a?b=c&d=e")
        XCTAssertNil(StowActivityAttributes.workspace(ofDeepLink: url))
    }

    func testWidgetContentKnowsItsWorkspace() {
        let state = testStore.store.load()
        XCTAssertEqual(WidgetContent.make(choice: .current, state: state).workspaceId, testStore.workspaceIds[0])
        XCTAssertEqual(WidgetContent.make(choice: .workspace(testStore.workspaceIds[1]), state: state).workspaceId,
                       testStore.workspaceIds[1])
    }

    func testOpeningADeepLinkSelectsTheWorkspaceAndReturnsTheLink() throws {
        let model = AppModel(store: testStore.store)
        let home = testStore.workspaceIds[1]
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "https://github.com", workspace: home))
        XCTAssertEqual(DeepLink.handle(url, model: model)?.absoluteString, "https://github.com")
        XCTAssertEqual(model.state.selectedWorkspaceId, home)
    }

    func testAnUnknownWorkspaceStillOpensTheLink() throws {
        let model = AppModel(store: testStore.store)
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "https://github.com", workspace: UUID()))
        XCTAssertEqual(DeepLink.handle(url, model: model)?.absoluteString, "https://github.com")
        XCTAssertEqual(model.state.selectedWorkspaceId, testStore.workspaceIds[0])
    }

    func testNonWebSchemesAreRefused() throws {
        let model = AppModel(store: testStore.store)
        let url = try XCTUnwrap(StowActivityAttributes.deepLink(for: "javascript:alert(1)", workspace: testStore.workspaceIds[1]))
        XCTAssertNil(DeepLink.handle(url, model: model))
        XCTAssertEqual(model.state.selectedWorkspaceId, testStore.workspaceIds[0], "a refused link switches nothing")
    }
}
