import XCTest
@testable import StowShared

/// Stands in for NSUbiquitousKeyValueStore so the tests never touch iCloud.
private final class FakeCloudStore: StringKeyValueStore {
    var values: [String: String] = [:]
    private(set) var synchronizeCount = 0
    func string(forKey key: String) -> String? { values[key] }
    func setString(_ value: String, forKey key: String) { values[key] = value }
    @discardableResult func synchronize() -> Bool { synchronizeCount += 1; return true }
}

@MainActor
final class SyncedTintPreferenceTests: XCTestCase {
    private var local: FakeCloudStore!
    private var cloud: FakeCloudStore!
    private var center: NotificationCenter!

    override func setUp() async throws {
        // In memory: a UserDefaults suite leaves a plist in ~/Library/Preferences per run.
        local = FakeCloudStore()
        cloud = FakeCloudStore()
        center = NotificationCenter()
    }

    private func makePreference() -> SyncedTintPreference {
        SyncedTintPreference(local: local, cloud: cloud, notificationCenter: center)
    }

    func testKeyMatchesTheOneStowThemeReads() {
        XCTAssertEqual(SyncedTintPreference.key, "StowTintMode")
    }

    func testDefaultsToFullWhenNothingIsStored() {
        XCTAssertEqual(makePreference().tint, .full)
    }

    func testSettingWritesLocallyAndToICloud() {
        let preference = makePreference()
        preference.set(.subtle)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "subtle")
        XCTAssertEqual(cloud.values["StowTintMode"], "subtle")
        XCTAssertEqual(preference.tint, .subtle)
        XCTAssertGreaterThan(cloud.synchronizeCount, 0)
    }

    func testSettingPostsAChangeNotification() {
        let preference = makePreference()
        let posted = expectation(forNotification: SyncedTintPreference.didChangeNotification, object: preference, notificationCenter: center)
        preference.set(.off)
        wait(for: [posted], timeout: 1)
    }

    func testStartAdoptsTheValueAlreadyInICloud() {
        local.setString("full", forKey: "StowTintMode")
        cloud.values["StowTintMode"] = "off"
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(preference.tint, .off)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "off")
    }

    func testStartPushesTheLocalChoiceWhenICloudHasNone() {
        local.setString("subtle", forKey: "StowTintMode")
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(cloud.values["StowTintMode"], "subtle")
    }

    func testStartIgnoresAnUnknownICloudValue() {
        local.setString("subtle", forKey: "StowTintMode")
        cloud.values["StowTintMode"] = "neon"
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(preference.tint, .subtle)
    }

    func testExternalChangeFromTheMacIsPulledIn() {
        let preference = makePreference()
        preference.start()
        let posted = expectation(forNotification: SyncedTintPreference.didChangeNotification, object: preference, notificationCenter: center)
        cloud.values["StowTintMode"] = "off"
        preference.handleExternalChange(changedKeys: ["StowTintMode"])
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(preference.tint, .off)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "off")
    }

    func testExternalChangeToOtherKeysIsIgnored() {
        local.setString("subtle", forKey: "StowTintMode")
        let preference = makePreference()
        cloud.values["StowTintMode"] = "off"
        preference.handleExternalChange(changedKeys: ["somethingElse"])
        XCTAssertEqual(preference.tint, .subtle)
    }
}
