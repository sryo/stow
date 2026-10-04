import XCTest
@testable import StowShared

@MainActor
final class CloudSyncPollTests: XCTestCase {
    override func tearDown() async throws {
        CloudSyncManager.shared.setPollsWhileActiveForTesting(false)
    }

    func testThePollRunsOnlyWhileTheAppIsActive() {
        let sync = CloudSyncManager.shared
        sync.setPollsWhileActiveForTesting(true)
        sync.appBecameActive()
        XCTAssertTrue(sync.isPolling)
        sync.appResignedActive()
        XCTAssertFalse(sync.isPolling, "X5: the 30s iCloud poll keeps running in the background")
        sync.appBecameActive()
        XCTAssertTrue(sync.isPolling, "coming back to the front resumes it")
    }

    func testNoPollWithoutSync() {
        let sync = CloudSyncManager.shared
        sync.setPollsWhileActiveForTesting(false)
        sync.appBecameActive()
        XCTAssertFalse(sync.isPolling)
    }
}
