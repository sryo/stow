import XCTest
import StowShared
@testable import StowIOS

final class ICloudStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func line(account: ICloudAccount = .available, availability: SyncAvailability = .active,
                      lastSync: Date? = nil, error: String? = nil) -> ICloudStatusLine {
        ICloudStatusLine.make(account: account, availability: availability, lastSync: lastSync, lastError: error, now: now)
    }

    func testSyncedJustNow() {
        XCTAssertEqual(line(lastSync: now.addingTimeInterval(-20)), ICloudStatusLine(text: "Synced just now", isError: false, action: nil))
    }

    func testSyncedMinutesAgo() {
        XCTAssertEqual(line(lastSync: now.addingTimeInterval(-125)).text, "Synced 2 min ago")
    }

    func testSyncedHoursAgo() {
        XCTAssertEqual(line(lastSync: now.addingTimeInterval(-3 * 3600 - 10)).text, "Synced 3 hr ago")
    }

    func testSyncedDaysAgo() {
        XCTAssertEqual(line(lastSync: now.addingTimeInterval(-2 * 86_400 - 10)).text, "Synced 2 days ago")
    }

    func testWaitingBeforeTheFirstSync() {
        XCTAssertEqual(line(), ICloudStatusLine(text: "Syncing…", isError: false, action: nil))
    }

    func testNotSignedInIsAnErrorWithAFix() {
        XCTAssertEqual(line(account: .noAccount), ICloudStatusLine(text: "Not signed in", isError: true, action: .openSettings))
    }

    func testRestrictedIsAnError() {
        XCTAssertEqual(line(account: .restricted).isError, true)
    }

    func testASyncFailureIsAnErrorWithRetry() {
        XCTAssertEqual(line(lastSync: now, error: "Network down"), ICloudStatusLine(text: "Couldn't sync", isError: true, action: .retry))
    }

    func testSyncOffForTestRunsIsNotAnError() {
        XCTAssertEqual(line(availability: .notConfigured), ICloudStatusLine(text: "Off", isError: false, action: nil))
    }

    func testUnknownAccountWhileWaitingIsNotFlagged() {
        XCTAssertFalse(line(account: .unknown).isError)
    }
}

@MainActor
final class PageColorTests: XCTestCase {
    func testLabelsUseTheMacsWords() {
        XCTAssertEqual(PageColor.options.map(\.title), ["Full", "Soft", "None"])
        XCTAssertEqual(PageColor.options.map(\.tint), [.full, .subtle, .off])
    }

    func testIncreaseContrastDropsFullToSoft() {
        XCTAssertEqual(PageColor.effective(.full, increaseContrast: true), .subtle)
        XCTAssertEqual(PageColor.effective(.full, increaseContrast: false), .full)
    }

    func testIncreaseContrastLeavesSoftAndNoneAlone() {
        XCTAssertEqual(PageColor.effective(.subtle, increaseContrast: true), .subtle)
        XCTAssertEqual(PageColor.effective(.off, increaseContrast: true), .off)
    }

    func testStorePublishesChangesFromTheSyncedPreference() {
        let local = TestDefaults()
        let cloud = TestDefaults()
        defer { local.remove(); cloud.remove() }
        let center = NotificationCenter()
        let preference = SyncedTintPreference(local: local.defaults, cloud: cloud.defaults, notificationCenter: center)
        let store = PageColorStore(preference: preference, notificationCenter: center)
        XCTAssertEqual(store.tint, .full)

        store.set(.off)
        XCTAssertEqual(store.tint, .off)
        XCTAssertEqual(cloud.defaults.string(forKey: "StowTintMode"), "off")

        // A change arriving from the Mac.
        cloud.defaults.set("subtle", forKey: "StowTintMode")
        preference.handleExternalChange(changedKeys: ["StowTintMode"])
        XCTAssertEqual(store.tint, .subtle)
    }
}
