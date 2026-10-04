import XCTest
import StowShared
@testable import StowIOS

@MainActor
final class LiveActivitySettingsTests: XCTestCase {
    private var testDefaults: TestDefaults!
    private var testStore: TestStore!

    override func setUp() async throws {
        testDefaults = TestDefaults()
        testStore = TestStore(workspaces: ["Work", "Home"], selected: 1)
    }

    override func tearDown() async throws {
        testDefaults.remove()
        testStore.remove()
    }

    private var settings: LiveActivitySettings { LiveActivitySettings(defaults: testDefaults.defaults) }

    func testOnByDefault() {
        XCTAssertTrue(settings.isEnabled)
    }

    func testKeepsTheExistingDefaultsKeySoTheOldToggleCarriesOver() {
        testDefaults.defaults.set(false, forKey: "StowShowInDynamicIsland")
        XCTAssertFalse(settings.isEnabled)
    }

    func testTurningItOffPersists() {
        var s = settings
        s.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
    }

    func testShowsTheOpenWorkspaceByDefault() {
        XCTAssertEqual(settings.shows, .current)
    }

    func testShowsChoicePersists() {
        var s = settings
        s.shows = .workspace(testStore.workspaceIds[0])
        XCTAssertEqual(settings.shows, .workspace(testStore.workspaceIds[0]))
    }

    func testResolvesTheOpenWorkspace() {
        let model = AppModel(store: testStore.store)
        XCTAssertEqual(settings.workspace(in: model).id, testStore.workspaceIds[1])
    }

    func testResolvesThePinnedWorkspaceWhileAnotherIsOpen() {
        let model = AppModel(store: testStore.store)
        var s = settings
        s.shows = .workspace(testStore.workspaceIds[0])
        XCTAssertEqual(s.workspace(in: model).id, testStore.workspaceIds[0])
    }

    func testDeletedPinnedWorkspaceFallsBackToTheOpenOne() {
        let model = AppModel(store: testStore.store)
        var s = settings
        s.shows = .workspace(UUID())
        XCTAssertEqual(s.workspace(in: model).id, testStore.workspaceIds[1])
    }

    func testTheLiveActivityStateCarriesThePinnedWorkspace() {
        let model = AppModel(store: testStore.store)
        var s = settings
        s.shows = .workspace(testStore.workspaceIds[0])
        let state = LiveActivityController.state(for: s.workspace(in: model))
        XCTAssertEqual(state.workspaceId, testStore.workspaceIds[0])
        XCTAssertEqual(state.name, "Work")
    }

    func testPickerOptionsListOpenWorkspaceFirstThenEveryWorkspace() {
        let model = AppModel(store: testStore.store)
        let options = LiveActivitySettings.options(for: model.workspaces)
        XCTAssertEqual(options.map(\.title), ["Open workspace", "Work", "Home"])
        XCTAssertEqual(options.first?.choice, .current)
    }
}
