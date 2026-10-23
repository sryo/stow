import XCTest
@testable import StowShared

/// Joining iCloud on a new Mac, or after an account switch, reads what's there before
/// uploading anything, and a same-named workspace never replaces the established one.
final class SyncJoinTests: XCTestCase {

    private var tempDir: URL!
    private var model: AppModel!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testANewMacsWorkspaceTakesOnTheEstablishedOnesIdentity() {
        let localId = model.workspaces[0].id
        let kept = model.addLink(urlString: "https://local.test", title: "local", parentId: nil)
        let remote = Workspace(id: UUID(), name: model.workspaces[0].name, colorId: .ruby, items: [], icon: .letter)

        model.adoptWorkspaceIdentityFromSync(remote: remote, replacingLocalId: localId)

        XCTAssertEqual(model.workspaces.map(\.id), [remote.id])
        XCTAssertEqual(model.workspaces[0].colorId, .ruby)
        XCTAssertEqual(model.workspaces[0].icon, .letter)
        XCTAssertNotNil(model.nodeById(kept), "local items stay")
        XCTAssertEqual(model.state.selectedWorkspaceId, remote.id)
    }

    func testANameMatchAdoptsTheRemoteWorkspaceWhenTheLocalOneWasNeverUploaded() {
        XCTAssertEqual(CloudSyncManager.resolveNameMatch(localWasUploaded: false), .adoptRemote)
        XCTAssertEqual(CloudSyncManager.resolveNameMatch(localWasUploaded: true), .mergeIntoLocal)
    }

    func testTheFirstUploadWaitsForAFetchToFinish() {
        var gate = JoinGate(joining: true)
        XCTAssertFalse(gate.allowsUploads)
        XCTAssertTrue(gate.fetchFinished(), "the first finished fetch triggers the full upload")
        XCTAssertTrue(gate.allowsUploads)
        XCTAssertFalse(gate.fetchFinished(), "only once")
    }

    func testAnAccountSwitchWaitsForAFetchAgain() {
        var gate = JoinGate(joining: false)
        XCTAssertTrue(gate.allowsUploads)
        gate.rejoin()
        XCTAssertFalse(gate.allowsUploads)
        XCTAssertTrue(gate.fetchFinished())
    }
}
