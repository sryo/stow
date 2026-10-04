import XCTest
@testable import StowShared

@MainActor
final class CloudSyncStatusTests: XCTestCase {
    override func tearDown() async throws {
        CloudSyncManager.shared.resetSyncStatusForTesting()
    }

    func testSuccessRecordsTheDateAndClearsTheError() {
        let manager = CloudSyncManager.shared
        manager.recordSyncFailure("Network unavailable")
        let date = Date(timeIntervalSince1970: 1_000)
        manager.recordSyncSuccess(at: date)
        XCTAssertEqual(manager.lastSyncDate, date)
        XCTAssertNil(manager.lastSyncError)
    }

    func testFailureKeepsTheLastGoodDate() {
        let manager = CloudSyncManager.shared
        let date = Date(timeIntervalSince1970: 2_000)
        manager.recordSyncSuccess(at: date)
        manager.recordSyncFailure("Quota exceeded")
        XCTAssertEqual(manager.lastSyncError, "Quota exceeded")
        XCTAssertEqual(manager.lastSyncDate, date)
    }

    func testStatusChangesArePosted() {
        let posted = expectation(forNotification: CloudSyncManager.statusDidChangeNotification, object: nil)
        CloudSyncManager.shared.recordSyncSuccess(at: Date())
        wait(for: [posted], timeout: 1)
    }
}
