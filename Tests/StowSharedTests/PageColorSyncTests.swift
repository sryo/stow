import XCTest
@testable import StowShared

private final class MemoryStore: PageColorKeyValueStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value as? String }
    @discardableResult func synchronize() -> Bool { true }
}

final class PageColorSyncTests: XCTestCase {
    private func defaults() -> UserDefaults { scratchDefaults() }

    func testChoosingAPageColorPublishesIt() {
        let store = MemoryStore()
        let sync = PageColorSync(store: store, defaults: defaults())
        sync.publish(.subtle)
        XCTAssertEqual(store.values[PageColorSync.key], "subtle")
    }

    func testAColorFromAnotherDeviceIsAdopted() {
        let store = MemoryStore()
        let local = defaults()
        let sync = PageColorSync(store: store, defaults: local)
        store.values[PageColorSync.key] = "off"
        XCTAssertEqual(sync.adoptRemote(), .off)
        XCTAssertEqual(local.string(forKey: PageColorSync.key), "off", "StowTheme.preferredTint reads this key")
    }

    func testNothingRemoteLeavesTheLocalChoice() {
        let local = defaults()
        local.set("subtle", forKey: PageColorSync.key)
        let sync = PageColorSync(store: MemoryStore(), defaults: local)
        XCTAssertNil(sync.adoptRemote())
        XCTAssertEqual(local.string(forKey: PageColorSync.key), "subtle")
    }

    func testUsesTheSameKeyAsTheLocalPreference() {
        XCTAssertEqual(PageColorSync.key, "StowTintMode")
    }
}
