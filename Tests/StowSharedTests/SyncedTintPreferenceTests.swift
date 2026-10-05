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
        preference.set(.off)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "off")
        XCTAssertEqual(cloud.values["StowTintMode"], "off")
        XCTAssertEqual(preference.tint, .off)
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
        local.setString("off", forKey: "StowTintMode")
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(cloud.values["StowTintMode"], "off")
    }

    func testStartIgnoresAnUnknownICloudValue() {
        local.setString("off", forKey: "StowTintMode")
        cloud.values["StowTintMode"] = "neon"
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(preference.tint, .off)
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
        local.setString("off", forKey: "StowTintMode")
        let preference = makePreference()
        cloud.values["StowTintMode"] = "full"
        preference.handleExternalChange(changedKeys: ["somethingElse"])
        XCTAssertEqual(preference.tint, .off)
    }

    // MARK: Soft is gone: it reads as Color

    func testAStoredSoftReadsAsColor() {
        local.setString("subtle", forKey: "StowTintMode")
        XCTAssertEqual(makePreference().tint, .full)
    }

    func testStartMovesSoftToFullInBothStores() {
        local.setString("subtle", forKey: "StowTintMode")
        cloud.values["StowTintMode"] = "subtle"
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(preference.tint, .full)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "full")
        XCTAssertEqual(cloud.values["StowTintMode"], "full", "the value syncs back as full")
    }

    func testStartPublishesALocalSoftAsFull() {
        local.setString("subtle", forKey: "StowTintMode")
        let preference = makePreference()
        preference.start()
        XCTAssertEqual(cloud.values["StowTintMode"], "full")
    }

    func testSoftFromAnotherDeviceArrivesAsFullAndSyncsBack() {
        local.setString("off", forKey: "StowTintMode")
        let preference = makePreference()
        preference.start()
        cloud.values["StowTintMode"] = "subtle"
        preference.handleExternalChange(changedKeys: ["StowTintMode"])
        XCTAssertEqual(preference.tint, .full)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "full")
        XCTAssertEqual(cloud.values["StowTintMode"], "full")
    }

    func testSoftCantBeChosen() {
        let preference = makePreference()
        preference.set(.subtle)
        XCTAssertEqual(local.string(forKey: "StowTintMode"), "full")
        XCTAssertEqual(cloud.values["StowTintMode"], "full")
    }

    func testThePageColorChoicesAreColorAndNeutral() {
        XCTAssertEqual(StowTheme.TintMode.choices, [.full, .off])
        XCTAssertEqual(StowTheme.TintMode.chosen(from: "subtle"), .full)
        XCTAssertEqual(StowTheme.TintMode.chosen(from: "off"), .off)
        XCTAssertNil(StowTheme.TintMode.chosen(from: "neon"))
    }

    func testStowThemeReadsAStoredSoftAsColor() {
        let saved = UserDefaults.standard.string(forKey: "StowTintMode")
        defer { UserDefaults.standard.set(saved, forKey: "StowTintMode") }
        UserDefaults.standard.set("subtle", forKey: "StowTintMode")
        XCTAssertEqual(StowTheme.preferredTint, .full)
    }
}
