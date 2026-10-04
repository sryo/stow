import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class FakeLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    var failNext = false
    func register() throws {
        if failNext { throw NSError(domain: "test", code: 1) }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
}

/// Collects the names of posted notifications.
final class NotificationRecorder: NSObject, @unchecked Sendable {
    private(set) var names: [Notification.Name] = []
    func start(_ watched: [Notification.Name]) {
        names = []
        for name in watched { NotificationCenter.default.addObserver(self, selector: #selector(note(_:)), name: name, object: nil) }
    }
    func stop() { NotificationCenter.default.removeObserver(self) }
    @objc private func note(_ notification: Notification) { names.append(notification.name) }
}

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var login: FakeLoginItem!
    private var tablineApplied: [TablineEdge?] = []
    private var accessibilityRequests = 0
    private var accessibility = true
    private var preferences: AppPreferences!
    private let recorder = NotificationRecorder()
    private var posted: [Notification.Name] { recorder.names }

    override func setUp() async throws {
        do {
            defaults = scratchDefaults()
            login = FakeLoginItem()
            tablineApplied = []
            accessibilityRequests = 0
            accessibility = true
            preferences = makePreferences()
            recorder.start([.alwaysOnTopSettingChanged, .attachmentSettingChanged, .stowAppPreferencesChanged, .tablineSettingChanged])
        }
    }

    override func tearDown() async throws {
        recorder.stop()
    }

    private func makePreferences() -> AppPreferences {
        AppPreferences(defaults: defaults, loginItem: login,
                       hasAccessibility: { [unowned self] in self.accessibility },
                       applyTabline: { [unowned self] in self.tablineApplied.append($0) },
                       requestAccessibility: { [unowned self] in self.accessibilityRequests += 1 })
    }

    // MARK: Browser dock

    func testDockDefaultsToNoneAndFloating() {
        XCTAssertEqual(preferences.dock, .none)
        XCTAssertEqual(preferences.windowMode, .floating)
        XCTAssertFalse(preferences.keepsOnTop)
    }

    func testDockWritesTheSettingsTheWindowCodeReads() {
        preferences.setDock(.left)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled))
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.sidebarPosition), "left")
        XCTAssertFalse(defaults.bool(forKey: TablineController.defaultsKey))
        XCTAssertEqual(preferences.windowMode, .attached)
        XCTAssertTrue(posted.contains(.attachmentSettingChanged))
        XCTAssertTrue(posted.contains(.stowAppPreferencesChanged))

        recorder.stop()
        recorder.start([.sidebarPositionChanged, .attachmentSettingChanged])
        preferences.setDock(.right)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.sidebarPosition), "right")
        XCTAssertEqual(posted, [.sidebarPositionChanged], "already attached: only the side moves")

        preferences.setDock(.top)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled), "one dock at a time")
        XCTAssertTrue(defaults.bool(forKey: TablineController.defaultsKey))
        XCTAssertEqual(defaults.string(forKey: TablineController.edgeKey), "top")
        XCTAssertEqual(tablineApplied, [.top])
        XCTAssertEqual(preferences.windowMode, .floating, "the Tabline leaves the window where it is")

        preferences.setDock(.bottom)
        XCTAssertEqual(defaults.string(forKey: TablineController.edgeKey), "bottom")
        XCTAssertEqual(tablineApplied, [.top, .bottom])

        preferences.setDock(.none)
        XCTAssertFalse(defaults.bool(forKey: TablineController.defaultsKey))
        XCTAssertEqual(tablineApplied, [.top, .bottom, nil])
        XCTAssertEqual(preferences.dock, .none)
    }

    func testDockSurvivesARelaunch() {
        preferences.setDock(.bottom)
        XCTAssertEqual(makePreferences().dock, .bottom)
    }

    func testTablineKeepsTheWindowOnTopIfChosen() {
        preferences.setKeepOnTop(true)
        preferences.setDock(.top)
        XCTAssertEqual(preferences.windowMode, .onTop)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled))
        preferences.setDock(.right)
        XCTAssertEqual(preferences.windowMode, .attached)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled), "On top only applies when not attached")
    }

    // MARK: Migration

    func testMigrationMapsTheOldSettingsOntoTheDock() {
        XCTAssertEqual(BrowserDock.migrated(attached: true, position: "left", tabline: false), .left)
        XCTAssertEqual(BrowserDock.migrated(attached: true, position: "right", tabline: false), .right)
        XCTAssertEqual(BrowserDock.migrated(attached: true, position: nil, tabline: false), .right, "right was the default side")
        XCTAssertEqual(BrowserDock.migrated(attached: true, position: "left", tabline: true), .left, "the sidebar wins over the Tabline")
        XCTAssertEqual(BrowserDock.migrated(attached: false, position: "left", tabline: true), .top)
        XCTAssertEqual(BrowserDock.migrated(attached: false, position: "left", tabline: false), .none)
    }

    func testExistingPreferencesAreMigratedOnFirstRead() {
        defaults.set(true, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
        defaults.set("left", forKey: UserDefaultsKeys.sidebarPosition)
        XCTAssertEqual(makePreferences().dock, .left)

        let tabline = scratchDefaults()
        tabline.set(true, forKey: TablineController.defaultsKey)
        let prefs = AppPreferences(defaults: tabline, loginItem: login, hasAccessibility: { true }, applyTabline: { _ in },
                                   requestAccessibility: {})
        XCTAssertEqual(prefs.dock, .top)
        XCTAssertEqual(tabline.string(forKey: AppPreferences.dockKey), "top", "migrated once and stored")
        XCTAssertEqual(tabline.string(forKey: TablineController.edgeKey), "top")
    }

    // MARK: Menu and shortcuts

    func testWindowModeMenuMapsOntoTheDock() {
        preferences.attachSide = { 0 }
        preferences.setWindowMode(.attached)
        XCTAssertEqual(preferences.dock, .left, "Attached picks up the side Stow sits on")
        preferences.setWindowMode(.onTop)
        XCTAssertEqual(preferences.dock, .none)
        XCTAssertEqual(preferences.windowMode, .onTop)
        preferences.attachSide = { nil }
        preferences.setWindowMode(.attached)
        XCTAssertEqual(preferences.dock, .left, "no browser window: the last side")
        preferences.setWindowMode(.floating)
        XCTAssertEqual(preferences.dock, .none)
        XCTAssertEqual(preferences.windowMode, .floating)

        preferences.setDock(.bottom)
        preferences.setWindowMode(.onTop)
        XCTAssertEqual(preferences.dock, .bottom, "Floating and On top don't touch the Tabline")
        XCTAssertEqual(preferences.windowMode, .onTop)
        preferences.attachSide = { 1 }
        preferences.setWindowMode(.attached)
        XCTAssertEqual(preferences.dock, .right, "Attached replaces the Tabline")
    }

    func testOptionCommandTSwitchesBetweenOnTopAndFloating() {
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .onTop)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .floating)
        preferences.setDock(.left)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .onTop, "from Attached, ⌥⌘T puts Stow on top")
        XCTAssertEqual(preferences.dock, .none)
        preferences.setDock(.top)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .floating)
        XCTAssertEqual(preferences.dock, .top, "the Tabline stays")
    }

    func testOptionCommandLTogglesTheTablineAndBack() {
        preferences.toggleTabline()
        XCTAssertEqual(preferences.dock, .top)
        XCTAssertTrue(preferences.tablineEnabled, "Show Tabline is checked")
        preferences.toggleTabline()
        XCTAssertEqual(preferences.dock, .none)
        preferences.setDock(.right)
        preferences.toggleTabline()
        XCTAssertEqual(preferences.dock, .top)
        preferences.toggleTabline()
        XCTAssertEqual(preferences.dock, .right, "back to the dock before the Tabline")
        preferences.setDock(.bottom)
        preferences.toggleTabline()
        XCTAssertEqual(preferences.dock, .right, "from the bottom Tabline too")
        XCTAssertFalse(preferences.tablineEnabled)
        XCTAssertEqual(makePreferences().dock, .right)
    }

    // MARK: Permissions

    func testChoosingAnEdgeWithoutAccessibilityAsksForIt() {
        accessibility = false
        preferences.setDock(.top)
        XCTAssertEqual(accessibilityRequests, 1, "starts the system permission flow instead of waiting silently")
        XCTAssertEqual(preferences.dock, .top, "the choice is kept")
        XCTAssertEqual(tablineApplied, [nil], "the strip waits for access")
        XCTAssertEqual(preferences.permissionNeeds.first, .accessibility(reason: "The Tabline needs Accessibility"))
        preferences.setDock(.left)
        XCTAssertEqual(accessibilityRequests, 2)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled))
        XCTAssertEqual(preferences.windowMode, .attached)
        preferences.setDock(.left)
        XCTAssertEqual(accessibilityRequests, 3, "choosing it again asks again")
        preferences.setDock(.none)
        XCTAssertEqual(accessibilityRequests, 3, "Not attached needs nothing")
    }

    func testChoosingAnEdgeWithAccessibilityDoesNotPrompt() {
        for dock in BrowserDock.allCases { preferences.setDock(dock) }
        XCTAssertEqual(accessibilityRequests, 0)
    }

    func testPendingDockAppliesOnceAccessibilityArrives() {
        accessibility = false
        preferences.setDock(.right)
        accessibility = true
        XCTAssertTrue(preferences.applyPendingAttachment())
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled))
        XCTAssertFalse(preferences.applyPendingAttachment(), "only once")

        accessibility = false
        preferences.setDock(.bottom)
        accessibility = true
        XCTAssertTrue(preferences.applyPendingTabline())
        XCTAssertEqual(tablineApplied.last, .bottom)
        XCTAssertFalse(preferences.applyPendingTabline(), "only once")
    }

    func testPermissionsLineAppearsOnlyWhenSomethingIsMissing() {
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .none, hasAccessibility: false, automationDenied: nil), [])
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .left, hasAccessibility: true, automationDenied: nil), [])
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .left, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "The sidebar needs Accessibility")])
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .bottom, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "The Tabline needs Accessibility")])
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .top, hasAccessibility: false, automationDenied: "Chrome"),
                       [.accessibility(reason: "The Tabline needs Accessibility"),
                        .automation(reason: "Switching to open tabs needs Automation for Chrome")])
    }

    func testTheSlidersCellIsBadgedWhileAPermissionIsMissing() {
        XCTAssertTrue(AppSheet.showsBadge(needs: [.automation(reason: "x")]))
        XCTAssertFalse(AppSheet.showsBadge(needs: []))
    }

    // MARK: Browser side

    func testAttachedSideFollowsTheEdgeYouAttachTo() {
        let browser = NSRect(x: 400, y: 100, width: 1000, height: 800)
        XCTAssertEqual(AppPreferences.side(of: NSRect(x: 60, y: 100, width: 340, height: 700), besides: browser), 0, "Stow left of the browser")
        XCTAssertEqual(AppPreferences.side(of: NSRect(x: 1300, y: 100, width: 340, height: 700), besides: browser), 1)
        XCTAssertNil(AppPreferences.side(of: NSRect(x: 0, y: 0, width: 10, height: 10), besides: nil))
    }

    // MARK: Open at login

    func testOpenAtLoginIsOffUntilTurnedOn() {
        XCTAssertFalse(preferences.openAtLogin)
        XCTAssertNil(preferences.setOpenAtLogin(true))
        XCTAssertTrue(preferences.openAtLogin)
        XCTAssertNil(preferences.setOpenAtLogin(false))
        XCTAssertFalse(preferences.openAtLogin)
    }

    func testOpenAtLoginReportsAFailure() {
        login.failNext = true
        XCTAssertNotNil(preferences.setOpenAtLogin(true))
        XCTAssertFalse(preferences.openAtLogin)
    }

    func testOpenAtLoginCountsAsOnWhileAwaitingApproval() {
        login.status = .requiresApproval
        XCTAssertTrue(preferences.openAtLogin)
    }

    // MARK: Page color

    func testPageColorSegmentsReadFullSoftNone() {
        XCTAssertEqual(StowTheme.TintMode.allCases.map(AppPreferences.tintTitle), ["Full", "Soft", "None"])
    }

    private func preferences(tint: SyncedTintPreference) -> AppPreferences {
        AppPreferences(defaults: defaults, loginItem: login, hasAccessibility: { true }, applyTabline: { _ in },
                       requestAccessibility: {}, tintPreference: tint)
    }

    func testPageColorIsPublishedToICloud() {
        let local = scratchDefaults(), cloud = scratchDefaults()
        let prefs = preferences(tint: SyncedTintPreference(local: local, cloud: cloud))
        prefs.setTint(.subtle)
        XCTAssertEqual(cloud.string(forKey: SyncedTintPreference.key), "subtle")
        XCTAssertEqual(prefs.tint, .subtle)
    }

    func testPageColorChosenOnAnotherDeviceRepaints() {
        let local = scratchDefaults(), cloud = scratchDefaults()
        let tint = SyncedTintPreference(local: local, cloud: cloud)
        let prefs = preferences(tint: tint)
        let repainted = expectation(forNotification: .stowTintModeChanged, object: nil)
        cloud.set("off", forKey: SyncedTintPreference.key)
        tint.handleExternalChange(changedKeys: [SyncedTintPreference.key])
        wait(for: [repainted], timeout: 1)
        XCTAssertEqual(prefs.tint, .off)
    }

    func testIncreaseContrastDropsFullToSoft() {
        XCTAssertEqual(AppPreferences.displayTint(preferred: .full, increaseContrast: true), .subtle)
        XCTAssertEqual(AppPreferences.displayTint(preferred: .full, increaseContrast: false), .full)
        XCTAssertEqual(AppPreferences.displayTint(preferred: .off, increaseContrast: true), .off)
    }
}
