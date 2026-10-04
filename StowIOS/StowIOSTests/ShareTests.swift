import XCTest
import StowShared
@testable import StowIOS

@MainActor
final class ShareDestinationTests: XCTestCase {
    private var testStore: TestStore!
    private var testDefaults: TestDefaults!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home", "Reading"], selected: 1)
        testDefaults = TestDefaults()
    }

    override func tearDown() async throws {
        testStore.remove()
        testDefaults.remove()
    }

    // MARK: Default destination

    func testDefaultsToTheWorkspaceLastOpenedInTheApp() {
        XCTAssertEqual(ShareSaver.defaultWorkspaceId(in: testStore.store.load()), testStore.workspaceIds[1])
    }

    func testDefaultsToTheFirstWorkspaceWhenNoneWasOpened() {
        let other = TestStore(workspaces: ["Work", "Home"], selected: nil)
        defer { other.remove() }
        XCTAssertEqual(ShareSaver.defaultWorkspaceId(in: other.store.load()), other.workspaceIds[0])
    }

    func testDefaultIgnoresAStaleSelection() {
        var state = testStore.store.load()
        state.selectedWorkspaceId = UUID()
        XCTAssertEqual(ShareSaver.defaultWorkspaceId(in: state), testStore.workspaceIds[0])
    }

    // MARK: Saving through AppModel

    func testSavesIntoTheChosenWorkspaceAndToDisk() throws {
        let model = AppModel(store: testStore.store)
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/a")!, title: "Example A",
            toWorkspace: testStore.workspaceIds[2], model: model, inbox: inbox))

        let found = try XCTUnwrap(model.link(id))
        XCTAssertEqual(found.workspace.id, testStore.workspaceIds[2])
        XCTAssertEqual(found.link.title, "Example A")
        XCTAssertEqual(found.link.url, "https://example.com/a")

        let reloaded = AppModel(store: testStore.store)
        XCTAssertEqual(reloaded.link(id)?.workspace.id, testStore.workspaceIds[2])
    }

    func testSavingIntoTheOpenWorkspaceWorks() throws {
        let model = AppModel(store: testStore.store)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/b")!, title: "B",
            toWorkspace: testStore.workspaceIds[1], model: model, inbox: ShareInbox(defaults: testDefaults.defaults)))
        XCTAssertEqual(model.link(id)?.workspace.id, testStore.workspaceIds[1])
    }

    func testSavingDoesNotChangeWhichWorkspaceIsOpen() {
        let model = AppModel(store: testStore.store)
        ShareSaver.save(url: URL(string: "https://example.com/c")!, title: "C",
                        toWorkspace: testStore.workspaceIds[0], model: model, inbox: ShareInbox(defaults: testDefaults.defaults))
        XCTAssertEqual(testStore.store.load().selectedWorkspaceId, testStore.workspaceIds[1])
    }

    func testSavingToAMissingWorkspaceFallsBackToTheDefault() throws {
        let model = AppModel(store: testStore.store)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/d")!, title: "D",
            toWorkspace: UUID(), model: model, inbox: ShareInbox(defaults: testDefaults.defaults)))
        XCTAssertEqual(model.link(id)?.workspace.id, testStore.workspaceIds[1])
    }

    func testSavingQueuesTheLinkForTheApp() throws {
        let model = AppModel(store: testStore.store)
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/e")!, title: "E",
            toWorkspace: testStore.workspaceIds[0], model: model, inbox: inbox))
        XCTAssertEqual(inbox.pending.map(\.node.id), [id])
        XCTAssertEqual(inbox.pending.first?.workspaceId, testStore.workspaceIds[0])
    }

    // MARK: The app picks shared links up

    func testTheRunningAppAbsorbsALinkSavedWhileItWasInMemory() throws {
        let app = AppModel(store: testStore.store)          // app is alive with the old state
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let extensionModel = AppModel(store: testStore.store)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/f")!, title: "F",
            toWorkspace: testStore.workspaceIds[2], model: extensionModel, inbox: inbox))
        XCTAssertNil(app.link(id))

        XCTAssertEqual(ShareSaver.absorb(inbox: inbox, into: app), 1)
        XCTAssertEqual(app.link(id)?.workspace.id, testStore.workspaceIds[2])
        XCTAssertTrue(inbox.pending.isEmpty)
        // And the app's next save keeps it.
        XCTAssertEqual(AppModel(store: testStore.store).link(id)?.workspace.id, testStore.workspaceIds[2])
    }

    func testAbsorbingTwiceDoesNotDuplicate() throws {
        let app = AppModel(store: testStore.store)
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/g")!, title: "G",
            toWorkspace: testStore.workspaceIds[0], model: AppModel(store: testStore.store), inbox: inbox))
        ShareSaver.absorb(inbox: inbox, into: app)
        ShareSaver.absorb(inbox: inbox, into: app)
        let count = app.workspaces.flatMap { $0.items.flattenLinks() }.filter { $0.id == id }.count
        XCTAssertEqual(count, 1)
    }

    func testAbsorbIsANoOpWhenTheLinkIsAlreadyLoaded() throws {
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let id = try XCTUnwrap(ShareSaver.save(
            url: URL(string: "https://example.com/h")!, title: "H",
            toWorkspace: testStore.workspaceIds[0], model: AppModel(store: testStore.store), inbox: inbox))
        let freshApp = AppModel(store: testStore.store)    // cold launch already read it from disk
        XCTAssertEqual(ShareSaver.absorb(inbox: inbox, into: freshApp), 0)
        XCTAssertNotNil(freshApp.link(id))
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    func testAbsorbPutsALinkWhoseWorkspaceWasDeletedIntoTheOpenWorkspace() throws {
        let app = AppModel(store: testStore.store)
        let inbox = ShareInbox(defaults: testDefaults.defaults)
        let link = StowShared.Link(id: UUID(), title: "I", url: "https://example.com/i", faviconPath: nil)
        inbox.append(PendingShare(workspaceId: UUID(), node: .link(link)))
        XCTAssertEqual(ShareSaver.absorb(inbox: inbox, into: app), 1)
        XCTAssertEqual(app.link(link.id)?.workspace.id, testStore.workspaceIds[1])
    }

    // MARK: Title

    func testPrefersTheTitleTheSharingAppProvided() {
        XCTAssertEqual(ShareSaver.title(shared: "Swift Forums", fetched: "Fetched", url: URL(string: "https://forums.swift.org")!), "Swift Forums")
    }

    func testIgnoresASharedTitleThatIsJustTheURL() {
        XCTAssertEqual(ShareSaver.title(shared: "https://forums.swift.org", fetched: "Fetched", url: URL(string: "https://forums.swift.org")!), "Fetched")
    }

    func testFallsBackToTheFetchedTitleThenTheHost() {
        XCTAssertEqual(ShareSaver.title(shared: nil, fetched: "Fetched", url: URL(string: "https://www.apple.com/x")!), "Fetched")
        XCTAssertEqual(ShareSaver.title(shared: "  ", fetched: nil, url: URL(string: "https://www.apple.com/x")!), "www.apple.com")
    }
}
