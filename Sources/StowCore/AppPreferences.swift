import AppKit
import ServiceManagement

/// What Open at login needs from SMAppService, so tests can stand in for it.
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class MainAppLoginItem: LoginItemControlling {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// App-wide preferences shared by the Settings page, the rail's app sheet and the menus,
/// so all of them change the same state the same way: window mode, browser side,
/// Tabline, Open at login and page color. Posts `.stowAppPreferencesChanged` after every
/// change (plus the older per-setting notifications the window code observes).
@MainActor
final class AppPreferences {
    static let shared = AppPreferences(defaults: .standard, loginItem: MainAppLoginItem(),
                                       hasAccessibility: AppPreferences.systemHasAccessibility,
                                       applyTabline: { TablineController.shared.isEnabled = $0 })

    /// Attached was chosen but Accessibility isn't granted yet; applied once it is.
    private(set) var attachRequested = false
    private let defaults: UserDefaults
    private let loginItem: LoginItemControlling
    private let accessibilityCheck: () -> Bool
    private let applyTabline: (Bool) -> Void

    init(defaults: UserDefaults, loginItem: LoginItemControlling,
         hasAccessibility: @escaping () -> Bool, applyTabline: @escaping (Bool) -> Void) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.accessibilityCheck = hasAccessibility
        self.applyTabline = applyTabline
    }

    private func changed() {
        NotificationCenter.default.post(name: .stowAppPreferencesChanged, object: nil)
    }

    // MARK: Page color

    static func tintTitle(_ tint: StowTheme.TintMode) -> String {
        switch tint {
        case .full: return "Full"
        case .subtle: return "Soft"
        case .off: return "None"
        }
    }

    /// Increase Contrast drops a full page color to Soft, so text keeps its contrast.
    static func displayTint(preferred: StowTheme.TintMode, increaseContrast: Bool) -> StowTheme.TintMode {
        preferred == .full && increaseContrast ? .subtle : preferred
    }

    /// The user's choice, as the segment shows it.
    var tint: StowTheme.TintMode { StowTheme.preferredTint }

    func setTint(_ tint: StowTheme.TintMode) {
        guard tint != StowTheme.preferredTint else { return }
        StowTheme.preferredTint = tint
        PageColorSync().publish(tint)
        NotificationCenter.default.post(name: .stowTintModeChanged, object: nil)
        changed()
    }

    // MARK: Window

    var windowMode: AppWindowMode {
        if attachRequested || defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled) { return .attached }
        if defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled) { return .onTop }
        return .floating
    }

    nonisolated static func systemHasAccessibility() -> Bool {
        #if DEBUG
        // STOW_NO_ACCESSIBILITY shows the missing-permission state on a Mac that has granted it.
        if ProcessInfo.processInfo.environment["STOW_NO_ACCESSIBILITY"] != nil { return false }
        #endif
        return AXIsProcessTrusted()
    }

    var hasAccessibility: Bool { accessibilityCheck() }

    /// The one setter for window mode: the sheet's segment, the Settings page and the
    /// Window ▸ Window Mode submenu all come through here.
    func setWindowMode(_ mode: AppWindowMode) {
        switch mode {
        case .floating:
            attachRequested = false
            setAttachment(false)
            setAlwaysOnTop(false)
        case .onTop:
            attachRequested = false
            setAttachment(false)
            setAlwaysOnTop(true)
        case .attached:
            setAlwaysOnTop(false)
            if hasAccessibility {
                attachRequested = false
                setAttachment(true)
            } else {
                attachRequested = true
            }
        }
        changed()
    }

    /// ⌥⌘T: On Top and Floating swap; from Attached it goes On Top.
    func toggleOnTop() {
        setWindowMode(windowMode == .onTop ? .floating : .onTop)
    }

    /// Attaches once Accessibility has been granted. Returns true when it just did.
    @discardableResult
    func applyPendingAttachment() -> Bool {
        guard attachRequested, hasAccessibility else { return false }
        attachRequested = false
        setAttachment(true)
        changed()
        return true
    }

    private func setAlwaysOnTop(_ enabled: Bool) {
        guard defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled) != enabled else { return }
        defaults.set(enabled, forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        NotificationCenter.default.post(name: .alwaysOnTopSettingChanged, object: nil, userInfo: ["enabled": enabled])
    }

    private func setAttachment(_ enabled: Bool) {
        guard defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled) != enabled else { return }
        defaults.set(enabled, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
        let position = defaults.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right"
        NotificationCenter.default.post(name: .attachmentSettingChanged, object: nil, userInfo: ["enabled": enabled, "position": position])
    }

    // MARK: Browser side

    /// 0 is left, 1 is right.
    var browserSide: Int {
        (defaults.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right") == "left" ? 0 : 1
    }

    func setBrowserSide(_ index: Int) {
        let position = index == 0 ? "left" : "right"
        defaults.set(position, forKey: UserDefaultsKeys.sidebarPosition)
        if defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled) {
            NotificationCenter.default.post(name: .sidebarPositionChanged, object: nil, userInfo: ["position": position])
        }
        changed()
    }

    /// Which side of the browser Stow sits on when it attaches: the side it's already on.
    /// Frames are in any one coordinate space. Nil when there's no browser window.
    static func side(of stow: NSRect, besides browser: NSRect?) -> Int? {
        guard let browser else { return nil }
        return stow.midX < browser.midX ? 0 : 1
    }

    // MARK: Tabline

    var tablineEnabled: Bool { defaults.bool(forKey: TablineController.defaultsKey) }

    /// The sheet's switch, the Window menu item and ⌥⌘L all come through here.
    func setTabline(_ enabled: Bool) {
        defaults.set(enabled, forKey: TablineController.defaultsKey)
        applyTabline(enabled)
        NotificationCenter.default.post(name: .tablineSettingChanged, object: nil, userInfo: ["enabled": enabled])
        changed()
    }

    func toggleTabline() {
        setTabline(!tablineEnabled)
    }

    // MARK: Open at login

    /// On once registered; "requires approval" counts as on, since the user asked for it.
    var openAtLogin: Bool {
        switch loginItem.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    var openAtLoginNeedsApproval: Bool { loginItem.status == .requiresApproval }

    /// Returns an error message when macOS refuses.
    @discardableResult
    func setOpenAtLogin(_ enabled: Bool) -> String? {
        defer { changed() }
        do {
            if enabled { try loginItem.register() } else { try loginItem.unregister() }
            return nil
        } catch {
            return "Couldn't change Open at login: \(error.localizedDescription)"
        }
    }

    // MARK: Permissions

    /// What's missing right now: Accessibility for Attached and Tabline, Automation for
    /// switching to an open tab in the browser you use.
    var permissionNeeds: [PermissionNeed] {
        AppSheet.permissionNeeds(windowMode: windowMode, tabline: tablineEnabled,
                                 hasAccessibility: hasAccessibility, automationDenied: automationDeniedBrowser())
    }

    /// The browser in front's name when the user has refused Stow Automation for it.
    func automationDeniedBrowser() -> String? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["STOW_NO_AUTOMATION"] { return name.isEmpty ? "Chrome" : name }
        #endif
        guard let bundleId = ActiveBrowserTracker.shared.lastActiveBundleId,
              BrowserManager.isRunning(bundleId: bundleId) else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return nil }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        return status == OSStatus(errAEEventNotPermitted) ? OpensInMenu.browserName(bundleId) : nil
    }

    func openAccessibilitySettings() {
        WindowAttachmentService.shared.requestAccessibilityPermissions()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func fix(_ need: PermissionNeed) {
        switch need {
        case .accessibility: openAccessibilitySettings()
        case .automation: openAutomationSettings()
        }
    }
}

extension StowTheme {
    /// The page color to draw with: the user's choice, softened under Increase Contrast.
    @MainActor
    static var displayTint: TintMode {
        AppPreferences.displayTint(preferred: preferredTint,
                                   increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }
}

extension Notification.Name {
    static let stowAppPreferencesChanged = Notification.Name("StowAppPreferencesChanged")
    static let tablineSettingChanged = Notification.Name("StowTablineSettingChanged")
}
