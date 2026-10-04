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
    private var tablineApplied: [Bool] = []
    private var accessibility = true
    private var preferences: AppPreferences!
    private let recorder = NotificationRecorder()
    private var posted: [Notification.Name] { recorder.names }

    override func setUp() async throws {
        do {
            defaults = scratchDefaults()
            login = FakeLoginItem()
            tablineApplied = []
            accessibility = true
            preferences = AppPreferences(defaults: defaults, loginItem: login,
                                         hasAccessibility: { [unowned self] in self.accessibility },
                                         applyTabline: { [unowned self] in self.tablineApplied.append($0) })
            recorder.start([.alwaysOnTopSettingChanged, .attachmentSettingChanged, .stowAppPreferencesChanged, .tablineSettingChanged])
        }
    }

    override func tearDown() async throws {
        recorder.stop()
    }

    // MARK: Window mode

    func testWindowModeDefaultsToFloating() {
        XCTAssertEqual(preferences.windowMode, .floating)
    }

    func testEverySetterNotifiesSoTheSheetAndMenuStayInStep() {
        preferences.setWindowMode(.onTop)
        XCTAssertEqual(preferences.windowMode, .onTop)
        XCTAssertTrue(posted.contains(.alwaysOnTopSettingChanged))
        XCTAssertTrue(posted.contains(.stowAppPreferencesChanged))
    }

    func testOptionCommandTSwitchesBetweenOnTopAndFloating() {
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .onTop)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .floating)
        preferences.setWindowMode(.attached)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.windowMode, .onTop, "from Attached, ⌥⌘T puts Stow on top")
    }

    func testAttachedWithoutAccessibilityWaitsForIt() {
        accessibility = false
        preferences.setWindowMode(.attached)
        XCTAssertEqual(preferences.windowMode, .attached)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled))
        accessibility = true
        XCTAssertTrue(preferences.applyPendingAttachment())
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled))
    }

    // MARK: Browser side

    func testBrowserSideFollowsTheEdgeYouAttachTo() {
        let browser = NSRect(x: 400, y: 100, width: 1000, height: 800)
        XCTAssertEqual(AppPreferences.side(of: NSRect(x: 60, y: 100, width: 340, height: 700), besides: browser), 0, "Stow left of the browser")
        XCTAssertEqual(AppPreferences.side(of: NSRect(x: 1300, y: 100, width: 340, height: 700), besides: browser), 1)
        XCTAssertNil(AppPreferences.side(of: NSRect(x: 0, y: 0, width: 10, height: 10), besides: nil))
    }

    // MARK: Tabline

    func testTablineDefaultsOffAndNotifiesEveryControl() {
        XCTAssertFalse(preferences.tablineEnabled)
        preferences.setTabline(true)
        XCTAssertTrue(preferences.tablineEnabled)
        XCTAssertEqual(tablineApplied, [true])
        XCTAssertTrue(posted.contains(.tablineSettingChanged))
        XCTAssertTrue(defaults.bool(forKey: TablineController.defaultsKey), "one source of truth with the controller")
        preferences.toggleTabline()
        XCTAssertFalse(preferences.tablineEnabled)
        XCTAssertEqual(tablineApplied, [true, false])
    }

    // MARK: Permissions

    func testPermissionsLineAppearsOnlyWhenSomethingIsMissing() {
        XCTAssertEqual(AppSheet.permissionNeeds(windowMode: .floating, tabline: false, hasAccessibility: false, automationDenied: nil), [])
        XCTAssertEqual(AppSheet.permissionNeeds(windowMode: .attached, tabline: false, hasAccessibility: true, automationDenied: nil), [])
        XCTAssertEqual(AppSheet.permissionNeeds(windowMode: .attached, tabline: false, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "Attached needs Accessibility")])
        XCTAssertEqual(AppSheet.permissionNeeds(windowMode: .floating, tabline: true, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "Tabline needs Accessibility")])
        XCTAssertEqual(AppSheet.permissionNeeds(windowMode: .attached, tabline: true, hasAccessibility: false, automationDenied: "Chrome"),
                       [.accessibility(reason: "Tabline and Attached need Accessibility"),
                        .automation(reason: "Switching to open tabs needs Automation for Chrome")])
    }

    func testTheSlidersCellIsBadgedWhileAPermissionIsMissing() {
        XCTAssertTrue(AppSheet.showsBadge(needs: [.automation(reason: "x")]))
        XCTAssertFalse(AppSheet.showsBadge(needs: []))
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

    func testIncreaseContrastDropsFullToSoft() {
        XCTAssertEqual(AppPreferences.displayTint(preferred: .full, increaseContrast: true), .subtle)
        XCTAssertEqual(AppPreferences.displayTint(preferred: .full, increaseContrast: false), .full)
        XCTAssertEqual(AppPreferences.displayTint(preferred: .off, increaseContrast: true), .off)
    }
}
