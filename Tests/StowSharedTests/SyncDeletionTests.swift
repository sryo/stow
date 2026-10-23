import XCTest
@testable import StowShared

/// A record deleted on another device stays deleted: an edit sent from a device that
/// hadn't seen the deletion yet doesn't bring it back.
final class SyncDeletionTests: XCTestCase {

    func testAnEditToARecordDeletedElsewhereDeletesItHere() {
        XCTAssertEqual(
            CloudSyncManager.resolveUnknownItem(sentFromServerCopy: true, existsLocally: true),
            .deleteLocally
        )
    }

    func testARecordAlreadyGoneLocallyIsDropped() {
        XCTAssertEqual(
            CloudSyncManager.resolveUnknownItem(sentFromServerCopy: true, existsLocally: false),
            .drop
        )
    }

    func testARecordNeverSeenOnTheServerIsUploadedAgain() {
        // Restoring an item after deleting it: the record goes up fresh, with no server copy behind it.
        XCTAssertEqual(
            CloudSyncManager.resolveUnknownItem(sentFromServerCopy: false, existsLocally: true),
            .reupload
        )
    }
}
