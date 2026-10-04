import XCTest
import Carbon
@testable import StowCore

private func freshDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "stow-tests-\(name)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

// MARK: - Stored shortcuts

final class ShortcutStoreTests: XCTestCase {
    let ctrlOptS = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey))
    let optCmdS = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey | cmdKey))

    func testToggleStowDefaultsToControlOptionS() {
        let store = ShortcutStore(defaults: freshDefaults())
        XCTAssertEqual(store.shortcut(for: .toggleStow), ctrlOptS, "⇧⌘B is Show Bookmarks Bar in every browser")
        XCTAssertEqual(HotkeyAction.toggleStow.defaultShortcut.displayString, "⌃⌥S")
    }

    func testStowFrontTabDefaultsToOptionCommandS() {
        let store = ShortcutStore(defaults: freshDefaults())
        XCTAssertEqual(store.shortcut(for: .stowFrontTab), optCmdS)
    }

    func testClearStaysCleared() {
        let defaults = freshDefaults()
        let store = ShortcutStore(defaults: defaults)
        store.clear(.toggleStow)
        XCTAssertNil(store.shortcut(for: .toggleStow), "Clear must not fall back to the default")
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .toggleStow), "and it survives a relaunch")
        store.clear(.stowFrontTab)
        XCTAssertNil(store.shortcut(for: .stowFrontTab))
    }

    func testRecordedShortcutRoundTripsPerAction() {
        let defaults = freshDefaults()
        let store = ShortcutStore(defaults: defaults)
        let f5 = KeyboardShortcut(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey))
        store.set(f5, for: .stowFrontTab)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .stowFrontTab), f5)
        XCTAssertEqual(store.shortcut(for: .toggleStow), ctrlOptS, "the other action keeps its default")
    }

    func testAnExplicitlyRecordedShiftCommandBIsKept() {
        let defaults = freshDefaults()
        let old = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey))
        // What older builds wrote when someone recorded ⇧⌘B themselves.
        defaults.set(try! JSONEncoder().encode(old), forKey: UserDefaultsKeys.toggleSidebarShortcut)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .toggleStow), old)
    }

    func testToggleStowKeepsTheOldDefaultsKey() {
        XCTAssertEqual(HotkeyAction.toggleStow.defaultsKey, UserDefaultsKeys.toggleSidebarShortcut)
        XCTAssertNotEqual(HotkeyAction.stowFrontTab.defaultsKey, HotkeyAction.toggleStow.defaultsKey)
    }
}

// MARK: - Conflicts

final class ShortcutConflictTests: XCTestCase {
    func testKnownBrowserShortcutsWarn() {
        let shiftCmdB = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey))
        guard let warning = ShortcutConflicts.browserWarning(for: shiftCmdB) else { return XCTFail("⇧⌘B should warn") }
        XCTAssertTrue(warning.contains("bookmarks bar"), warning)
        let cmdL = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_L), carbonModifiers: UInt32(cmdKey))
        XCTAssertNotNil(ShortcutConflicts.browserWarning(for: cmdL))
    }

    func testTheDefaultsDontWarn() {
        for action in HotkeyAction.allCases {
            XCTAssertNil(ShortcutConflicts.browserWarning(for: action.defaultShortcut), "\(action)")
            XCTAssertNil(ShortcutConflicts.systemRejection(for: action.defaultShortcut), "\(action)")
        }
    }

    func testSystemShortcutsAreStillRefused() {
        let cmdQ = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey))
        XCTAssertNotNil(ShortcutConflicts.systemRejection(for: cmdQ))
    }

    func testTheOtherStowShortcutIsRefused() {
        let store = ShortcutStore(defaults: freshDefaults())
        let reason = ShortcutConflicts.stowRejection(for: HotkeyAction.stowFrontTab.defaultShortcut, recording: .toggleStow, store: store)
        XCTAssertEqual(reason, "⌥⌘S already stows the front tab.")
        XCTAssertNil(ShortcutConflicts.stowRejection(for: HotkeyAction.toggleStow.defaultShortcut, recording: .toggleStow, store: store),
                     "re-recording its own shortcut is fine")
    }
}

// MARK: - Several global hotkeys

@MainActor
final class GlobalHotkeyServiceTests: XCTestCase {
    // Combinations nobody else is likely to hold.
    let a = KeyboardShortcut(keyCode: UInt32(kVK_F17), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
    let b = KeyboardShortcut(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))

    override func tearDown() {
        MainActor.assumeIsolated { GlobalHotkeyService.shared.unregisterAll() }
    }

    func testRegistersOneHotkeyPerAction() {
        let service = GlobalHotkeyService.shared
        XCTAssertTrue(service.register(a, for: .toggleStow))
        XCTAssertTrue(service.register(b, for: .stowFrontTab))
        XCTAssertEqual(service.registeredShortcut(for: .toggleStow), a)
        XCTAssertEqual(service.registeredShortcut(for: .stowFrontTab), b)
    }

    func testUnregisteringOneKeepsTheOther() {
        let service = GlobalHotkeyService.shared
        service.register(a, for: .toggleStow)
        service.register(b, for: .stowFrontTab)
        service.unregister(.toggleStow)
        XCTAssertNil(service.registeredShortcut(for: .toggleStow))
        XCTAssertEqual(service.registeredShortcut(for: .stowFrontTab), b)
    }

    func testReRegisteringReplaces() {
        let service = GlobalHotkeyService.shared
        service.register(a, for: .stowFrontTab)
        service.register(b, for: .stowFrontTab)
        XCTAssertEqual(service.registeredShortcut(for: .stowFrontTab), b)
        // a is free again, so another action can take it.
        XCTAssertTrue(service.register(a, for: .toggleStow))
    }

    func testHotkeyIdsMapBackToTheirAction() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(HotkeyAction(hotkeyId: action.hotkeyId), action)
        }
        XCTAssertNil(HotkeyAction(hotkeyId: 99))
    }

    func testApplyRegistersWhatIsStoredAndSkipsCleared() {
        let store = ShortcutStore(defaults: freshDefaults())
        store.set(a, for: .toggleStow)
        store.clear(.stowFrontTab)
        GlobalHotkeyService.shared.apply(store)
        XCTAssertEqual(GlobalHotkeyService.shared.registeredShortcut(for: .toggleStow), a)
        XCTAssertNil(GlobalHotkeyService.shared.registeredShortcut(for: .stowFrontTab))
    }
}
