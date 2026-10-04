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
/// so all of them change the same state the same way: where Stow docks on the browser,
/// On top, Open at login and page color. Posts `.stowAppPreferencesChanged` after every
/// change (plus the older per-setting notifications the window code observes).
@MainActor
final class AppPreferences {
    static let shared = AppPreferences(defaults: .standard, loginItem: MainAppLoginItem(),
                                       hasAccessibility: AppPreferences.systemHasAccessibility,
                                       applyTabline: { TablineController.shared.setRunning(edge: $0) },
                                       requestAccessibility: { AppPreferences.promptForAccessibility() })

    /// Which side of the browser Stow is on right now (0 left, 1 right), read when the
    /// Window menu's Attached docks it. Nil without a browser window.
    var attachSide: (() -> Int?)?
    private let defaults: UserDefaults
    private let loginItem: LoginItemControlling
    private let accessibilityCheck: () -> Bool
    /// Runs the Tabline on an edge, or stops it with nil.
    private let applyTabline: (TablineEdge?) -> Void
    /// Starts the system's Accessibility prompt.
    private let requestAccessibility: () -> Void
    /// Page color, mirrored to iCloud so the iPhone shows the same one.
    private let tintPreference: SyncedTintPreference
    private var tintObserver: NSObjectProtocol?

    init(defaults: UserDefaults, loginItem: LoginItemControlling,
         hasAccessibility: @escaping () -> Bool, applyTabline: @escaping (TablineEdge?) -> Void,
         requestAccessibility: @escaping () -> Void,
         tintPreference: SyncedTintPreference = .shared) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.accessibilityCheck = hasAccessibility
        self.applyTabline = applyTabline
        self.requestAccessibility = requestAccessibility
        self.tintPreference = tintPreference
        // Fires for a local choice and for one made on another device alike.
        tintObserver = NotificationCenter.default.addObserver(
            forName: SyncedTintPreference.didChangeNotification, object: tintPreference, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .stowTintModeChanged, object: nil)
                self?.changed()
            }
        }
    }

    /// Reconciles page color with iCloud and follows changes from other devices.
    func startTintSync() {
        tintPreference.start()
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
    var tint: StowTheme.TintMode { tintPreference.tint }

    /// Saves locally and to iCloud; the preference's change notification repaints.
    func setTint(_ tint: StowTheme.TintMode) {
        guard tint != tintPreference.tint else { return }
        tintPreference.set(tint)
    }

    // MARK: Browser dock

    static let dockKey = "browserDock"
    /// The dock ⌥⌘L goes back to when it hides the Tabline.
    static let dockBeforeTablineKey = "browserDockBeforeTabline"

    /// Where Stow sits on the browser: the one source of truth for the attached sidebar and
    /// the Tabline. Read for the first time, it's worked out from the older settings.
    var dock: BrowserDock {
        if let stored = defaults.string(forKey: Self.dockKey), let dock = BrowserDock(rawValue: stored) { return dock }
        let migrated = BrowserDock.migrated(attached: defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled),
                                            position: defaults.string(forKey: UserDefaultsKeys.sidebarPosition),
                                            tabline: defaults.bool(forKey: TablineController.defaultsKey))
        defaults.set(migrated.rawValue, forKey: Self.dockKey)
        defaults.set(migrated.isTabline, forKey: TablineController.defaultsKey)
        defaults.set((migrated.tablineEdge ?? .top).rawValue, forKey: TablineController.edgeKey)
        return migrated
    }

    /// The picker, the Window ▸ Window Mode submenu, ⌥⌘T and ⌥⌘L all come through here.
    /// Without Accessibility the choice is kept, the system permission prompt starts and
    /// the permissions line offers Fix…; the dock applies once access is granted.
    func setDock(_ newDock: BrowserDock) {
        let old = dock
        if newDock != .none, !hasAccessibility { requestAccessibility() }
        guard newDock != old else { return }
        if newDock.isTabline, !old.isTabline {
            defaults.set(old.rawValue, forKey: Self.dockBeforeTablineKey)
        }
        defaults.set(newDock.rawValue, forKey: Self.dockKey)

        if let position = newDock.sidebarPosition {
            let moved = defaults.string(forKey: UserDefaultsKeys.sidebarPosition) != position
            defaults.set(position, forKey: UserDefaultsKeys.sidebarPosition)
            setAlwaysOnTop(false)
            if defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled) {
                if moved {
                    NotificationCenter.default.post(name: .sidebarPositionChanged, object: nil, userInfo: ["position": position])
                }
            } else if hasAccessibility {
                setAttachment(true)
            }
        } else {
            setAttachment(false)
        }

        if old.isTabline || newDock.isTabline {
            defaults.set(newDock.isTabline, forKey: TablineController.defaultsKey)
            if let edge = newDock.tablineEdge { defaults.set(edge.rawValue, forKey: TablineController.edgeKey) }
            tablineRunning = newDock.isTabline && hasAccessibility
            applyTabline(tablineRunning ? newDock.tablineEdge : nil)
            NotificationCenter.default.post(name: .tablineSettingChanged, object: nil, userInfo: ["enabled": newDock.isTabline])
        }
        changed()
    }

    // MARK: Window

    /// Floating, On top or Attached, as the Window ▸ Window Mode submenu shows it. The
    /// Tabline leaves the window where it is, so with it Stow is Floating or On top.
    var windowMode: AppWindowMode {
        if dock.isSidebar { return .attached }
        return keepsOnTop ? .onTop : .floating
    }

    /// On top for the free-floating window; it doesn't apply while attached.
    var keepsOnTop: Bool { defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled) }

    func setKeepOnTop(_ enabled: Bool) {
        if enabled, dock.isSidebar { setDock(.none) }
        setAlwaysOnTop(enabled)
        changed()
    }

    nonisolated static func systemHasAccessibility() -> Bool {
        #if DEBUG
        // STOW_NO_ACCESSIBILITY shows the missing-permission state on a Mac that has granted it.
        if ProcessInfo.processInfo.environment["STOW_NO_ACCESSIBILITY"] != nil { return false }
        #endif
        return AXIsProcessTrusted()
    }

    var hasAccessibility: Bool { accessibilityCheck() }

    /// Window ▸ Window Mode: Floating and On top leave a Tabline alone and drop the
    /// sidebar; Attached docks on the side Stow sits on (or the last side).
    func setWindowMode(_ mode: AppWindowMode) {
        switch mode {
        case .floating, .onTop:
            if dock.isSidebar { setDock(.none) }
            setAlwaysOnTop(mode == .onTop)
            changed()
        case .attached:
            if dock.isSidebar { return setDock(dock) }
            let side = attachSide?() ?? ((defaults.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right") == "left" ? 0 : 1)
            setDock(side == 0 ? .left : .right)
        }
    }

    /// ⌥⌘T: On Top and Floating swap; from Attached it goes On Top.
    func toggleOnTop() {
        setWindowMode(windowMode == .onTop ? .floating : .onTop)
    }

    /// Attaches once Accessibility has been granted. Returns true when it just did.
    @discardableResult
    func applyPendingAttachment() -> Bool {
        guard dock.isSidebar, !defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled), hasAccessibility else { return false }
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

    /// Which side of the browser Stow sits on when it attaches: the side it's already on.
    /// Frames are in any one coordinate space. Nil when there's no browser window.
    static func side(of stow: NSRect, besides browser: NSRect?) -> Int? {
        guard let browser else { return nil }
        return stow.midX < browser.midX ? 0 : 1
    }

    // MARK: Tabline

    /// Window ▸ Show Tabline is checked while the Tabline rides either edge.
    var tablineEnabled: Bool { dock.isTabline }

    /// Whether the strip is running; it waits for Accessibility while the dock asks for it.
    private var tablineRunning = false

    /// ⌥⌘L: the Tabline on top, or back to the dock before it.
    func toggleTabline() {
        if dock.isTabline {
            let previous = defaults.string(forKey: Self.dockBeforeTablineKey).flatMap(BrowserDock.init(rawValue:)) ?? .none
            setDock(previous.isTabline ? .none : previous)
        } else {
            setDock(.top)
        }
    }

    /// Starts the strip once Accessibility arrives (or at launch). Returns true when it did.
    @discardableResult
    func applyPendingTabline() -> Bool {
        guard let edge = dock.tablineEdge, !tablineRunning, hasAccessibility else { return false }
        tablineRunning = true
        applyTabline(edge)
        changed()
        return true
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
        AppSheet.permissionNeeds(dock: dock, hasAccessibility: hasAccessibility, automationDenied: automationDeniedBrowser())
    }

    /// The system's "Stow would like to control this computer" prompt.
    static func promptForAccessibility() {
        #if DEBUG
        // The simulated missing-permission state has nothing to prompt for.
        if ProcessInfo.processInfo.environment["STOW_NO_ACCESSIBILITY"] != nil { return }
        #endif
        WindowAttachmentService.shared.requestAccessibilityPermissions()
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
        Self.promptForAccessibility()
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
