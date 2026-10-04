import XCTest
import StowShared
@testable import StowIOS

@MainActor
final class ShareSheetModelTests: XCTestCase {
    private var testStore: TestStore!
    private var testDefaults: TestDefaults!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home", "Reading"], selected: 2)
        testDefaults = TestDefaults()
    }

    override func tearDown() async throws {
        testStore.remove()
        testDefaults.remove()
    }

    private func makeModel(sharedTitle: String? = nil, fetcher: @escaping ShareSheetModel.TitleFetcher = { _ in nil }) -> ShareSheetModel {
        ShareSheetModel(
            url: URL(string: "https://example.com/page")!,
            sharedTitle: sharedTitle,
            store: testStore.store,
            inbox: ShareInbox(defaults: testDefaults.defaults),
            fetchTitle: fetcher
        )
    }

    func testChipsListEveryWorkspaceInOrder() {
        XCTAssertEqual(makeModel().workspaces.map(\.name), ["Work", "Home", "Reading"])
    }

    func testTheLastOpenedWorkspaceIsPreselected() {
        XCTAssertEqual(makeModel().selectedWorkspaceId, testStore.workspaceIds[2])
    }

    func testShowsTheHostUntilATitleArrives() {
        XCTAssertEqual(makeModel().title, "example.com")
    }

    func testFetchesARealTitle() async {
        let model = makeModel(fetcher: { _ in "Example Page" })
        await model.loadTitle()
        XCTAssertEqual(model.title, "Example Page")
    }

    func testKeepsTheSharingAppsTitleOverAFetchedOne() async {
        let model = makeModel(sharedTitle: "From Safari", fetcher: { _ in "Fetched" })
        await model.loadTitle()
        XCTAssertEqual(model.title, "From Safari")
    }

    func testSaveGoesToThePickedChip() throws {
        let model = makeModel(fetcher: { _ in "Example Page" })
        model.selectedWorkspaceId = testStore.workspaceIds[0]
        let id = try XCTUnwrap(model.save())
        let saved = try XCTUnwrap(AppModel(store: testStore.store).link(id))
        XCTAssertEqual(saved.workspace.id, testStore.workspaceIds[0])
        XCTAssertEqual(saved.link.url, "https://example.com/page")
    }

    func testSaveUsesTheFetchedTitle() async throws {
        let model = makeModel(fetcher: { _ in "Example Page" })
        await model.loadTitle()
        let id = try XCTUnwrap(model.save())
        XCTAssertEqual(AppModel(store: testStore.store).link(id)?.link.title, "Example Page")
    }

    func testSaveWaitsBrieflyForATitleStillLoading() async throws {
        let model = makeModel(fetcher: { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return "Slow Title"
        })
        let loading = Task { await model.loadTitle() }
        await Task.yield()
        let saved = await model.saveWhenTitleIsReady(timeout: .seconds(2))
        let id = try XCTUnwrap(saved)
        XCTAssertEqual(AppModel(store: testStore.store).link(id)?.link.title, "Slow Title")
        await loading.value
    }

    func testSaveDoesNotWaitForeverForATitle() async throws {
        let model = makeModel(fetcher: { _ in
            try? await Task.sleep(for: .seconds(5))
            return "Too Late"
        })
        let loading = Task { await model.loadTitle() }
        await Task.yield()
        let started = Date()
        let saved = await model.saveWhenTitleIsReady(timeout: .milliseconds(300))
        let id = try XCTUnwrap(saved)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(AppModel(store: testStore.store).link(id)?.link.title, "example.com")
        loading.cancel()
    }
}
