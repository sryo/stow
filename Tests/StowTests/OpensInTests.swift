import XCTest
@testable import StowCore

// MARK: - Stored per workspace, per Mac

final class OpensInStoreTests: XCTestCase {
    let work = UUID(), home = UUID()

    func testDefaultsToTheBrowserImUsing() {
        let store = OpensInStore(defaults: scratchDefaults())
        XCTAssertNil(store.choice(for: work))
    }

    func testBrowserAndProfileAreStoredTogetherPerWorkspace() {
        let defaults = scratchDefaults()
        let store = OpensInStore(defaults: defaults)
        store.set(OpensIn(bundleId: "com.google.Chrome", profile: "Profile 1"), for: work)
        store.set(OpensIn(bundleId: "com.apple.Safari", profile: nil), for: home)
        let reread = OpensInStore(defaults: defaults)
        XCTAssertEqual(reread.choice(for: work), OpensIn(bundleId: "com.google.Chrome", profile: "Profile 1"))
        XCTAssertEqual(reread.choice(for: home), OpensIn(bundleId: "com.apple.Safari", profile: nil))
        reread.set(nil, for: work)
        XCTAssertNil(OpensInStore(defaults: defaults).choice(for: work), "back to the browser I'm using")
    }

    func testAPinnedGlobalBrowserIsCopiedOntoEveryWorkspace() {
        let defaults = scratchDefaults()
        defaults.set(false, forKey: UserDefaultsKeys.openLinksInActiveBrowser)
        defaults.set("com.google.Chrome", forKey: UserDefaultsKeys.defaultBrowserBundleId)
        let a = Workspace(id: work, name: "Work", colorId: .ocean, items: [], browserProfiles: ["com.google.Chrome": "Profile 2"])
        let b = Workspace(id: home, name: "Home", colorId: .ruby, items: [])
        let store = OpensInStore(defaults: defaults)
        store.migrateIfNeeded(workspaces: [a, b])
        XCTAssertEqual(store.choice(for: work), OpensIn(bundleId: "com.google.Chrome", profile: "Profile 2"))
        XCTAssertEqual(store.choice(for: home), OpensIn(bundleId: "com.google.Chrome", profile: nil))
    }

    func testASyncedProfileBecomesThatWorkspacesBrowserAndProfile() {
        let defaults = scratchDefaults()
        let a = Workspace(id: work, name: "Work", colorId: .ocean, items: [], browserProfiles: ["com.google.Chrome": "Profile 1"])
        let b = Workspace(id: home, name: "Home", colorId: .ruby, items: [])
        let store = OpensInStore(defaults: defaults)
        store.migrateIfNeeded(workspaces: [a, b])
        XCTAssertEqual(store.choice(for: work), OpensIn(bundleId: "com.google.Chrome", profile: "Profile 1"))
        XCTAssertNil(store.choice(for: home))
    }

    func testMigrationRunsOnceAndNeverOverwritesAChoice() {
        let defaults = scratchDefaults()
        let store = OpensInStore(defaults: defaults)
        store.migrateIfNeeded(workspaces: [])
        let a = Workspace(id: work, name: "Work", colorId: .ocean, items: [], browserProfiles: ["com.google.Chrome": "Profile 1"])
        store.migrateIfNeeded(workspaces: [a])
        XCTAssertNil(store.choice(for: work), "already migrated")
    }
}

// MARK: - One way to pick the browser

final class LinkTargetTests: XCTestCase {
    let installed: Set<String> = ["com.google.Chrome", "com.apple.Safari", "com.google.Chrome.canary"]
    func resolve(_ choice: OpensIn?, active: String?, system: String? = "com.apple.Safari", option: Bool = false) -> LinkTarget {
        LinkTarget.resolve(choice: choice, activeBrowser: active, systemDefault: system,
                           isInstalled: { self.installed.contains($0) }, forceNewTab: option)
    }

    func testBrowserImUsingFollowsTheActiveBrowserWithoutAProfile() {
        let target = resolve(nil, active: "com.google.Chrome.canary")
        XCTAssertEqual(target.bundleId, "com.google.Chrome.canary")
        XCTAssertNil(target.profile)
        XCTAssertTrue(target.focusesOpenTab)
    }

    func testBrowserImUsingFallsBackToTheSystemDefault() {
        XCTAssertEqual(resolve(nil, active: nil).bundleId, "com.apple.Safari")
        XCTAssertEqual(resolve(nil, active: "org.uninstalled.Browser").bundleId, "com.apple.Safari")
    }

    func testAPinnedBrowserAndProfileApplyEvenWhileAnotherBrowserIsActive() {
        // The old bug: a workspace profile only applied when the active browser happened
        // to be the browser the profile was filed under.
        let target = resolve(OpensIn(bundleId: "com.google.Chrome", profile: "Profile 1"), active: "com.apple.Safari")
        XCTAssertEqual(target.bundleId, "com.google.Chrome")
        XCTAssertEqual(target.profile, "Profile 1")
        XCTAssertTrue(target.focusesOpenTab, "switches to an open tab first, in whichever browser has it")
    }

    func testAnUninstalledPinnedBrowserFallsBackToTheBrowserImUsing() {
        let target = resolve(OpensIn(bundleId: "com.vivaldi.Vivaldi", profile: "Default"), active: "com.google.Chrome")
        XCTAssertEqual(target.bundleId, "com.google.Chrome")
        XCTAssertNil(target.profile)
    }

    /// The open-tab dot means "open in some browser", so a click switches to that tab
    /// wherever it is; Option is the way to get a fresh tab anyway.
    func testOptionOpensAFreshTabInsteadOfSwitching() {
        XCTAssertFalse(resolve(nil, active: "com.google.Chrome", option: true).focusesOpenTab)
        XCTAssertFalse(resolve(OpensIn(bundleId: "com.apple.Safari", profile: nil), active: nil, option: true).focusesOpenTab)
    }
}

// MARK: - Labels

final class OpensInLabelTests: XCTestCase {
    func testLabelsPairTheBrowserWithItsProfile() {
        XCTAssertEqual(OpensIn.label(browserName: "Chrome", profileName: "Work"), "Chrome · Work")
        XCTAssertEqual(OpensIn.label(browserName: "Safari", profileName: nil), "Safari")
        XCTAssertEqual(OpensIn.browserImUsing, "Browser I’m using")
    }

    func testShortBrowserNamesDropTheVendor() {
        XCTAssertEqual(OpensIn.shortName("Google Chrome"), "Chrome")
        XCTAssertEqual(OpensIn.shortName("Google Chrome Canary"), "Chrome Canary")
        XCTAssertEqual(OpensIn.shortName("Microsoft Edge"), "Edge")
        XCTAssertEqual(OpensIn.shortName("Safari"), "Safari")
    }
}
