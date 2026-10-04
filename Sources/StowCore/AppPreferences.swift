import AppKit

/// App-wide preferences shared by the Settings page and the rail's app sheet, so both
/// change the same state the same way: theme, page color, window mode, browser side and
/// the browser links open in. Posts `.stowAppPreferencesChanged` after every change.
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()

    enum Theme: Int, CaseIterable {
        case system, light, dark

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    static let themeKey = "appTheme"

    /// Attached was chosen but Accessibility isn't granted yet; applied once it is.
    private(set) var attachRequested = false
    private let defaults = UserDefaults.standard

    private init() {}

    private func changed() {
        NotificationCenter.default.post(name: .stowAppPreferencesChanged, object: nil)
    }

    // MARK: Theme

    var theme: Theme {
        Theme(rawValue: defaults.integer(forKey: Self.themeKey)) ?? .system
    }

    func setTheme(_ theme: Theme) {
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        NSApp.appearance = theme.appearance
        changed()
    }

    /// Applies the stored theme at launch (a debug STOW_APPEARANCE wins).
    func applyStoredTheme() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STOW_APPEARANCE"] != nil { return }
        #endif
        NSApp.appearance = theme.appearance
    }

    // MARK: Page color

    var tint: StowTheme.TintMode { StowTheme.preferredTint }

    func setTint(_ tint: StowTheme.TintMode) {
        guard tint != StowTheme.preferredTint else { return }
        StowTheme.preferredTint = tint
        NotificationCenter.default.post(name: .stowTintModeChanged, object: nil)
        changed()
    }

    // MARK: Window

    var windowMode: AppWindowMode {
        if attachRequested || defaults.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled) { return .attached }
        if defaults.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled) { return .onTop }
        return .floating
    }

    var hasAccessibility: Bool {
        #if DEBUG
        // STOW_NO_ACCESSIBILITY shows the missing-permission state on a Mac that has granted it.
        if ProcessInfo.processInfo.environment["STOW_NO_ACCESSIBILITY"] != nil { return false }
        #endif
        return WindowAttachmentService.shared.checkAccessibilityPermissions()
    }

    var needsAccessibility: Bool {
        AppSheet.showsBadge(windowMode: windowMode, hasAccessibility: hasAccessibility)
    }

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

    /// Attaches once Accessibility has been granted. Returns true when it just did.
    @discardableResult
    func applyPendingAttachment() -> Bool {
        guard attachRequested, hasAccessibility else { return false }
        attachRequested = false
        setAttachment(true)
        changed()
        return true
    }

    func openAccessibilitySettings() {
        WindowAttachmentService.shared.requestAccessibilityPermissions()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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

}

extension Notification.Name {
    static let stowAppPreferencesChanged = Notification.Name("StowAppPreferencesChanged")
}
