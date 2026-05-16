import Foundation

extension Notification.Name {
    public static let defaultBrowserChanged = Notification.Name("defaultBrowserChanged")
    public static let alwaysOnTopSettingChanged = Notification.Name("alwaysOnTopSettingChanged")
    public static let attachmentSettingChanged = Notification.Name("attachmentSettingChanged")
    public static let sidebarPositionChanged = Notification.Name("sidebarPositionChanged")
    public static let toggleSidebarShortcutChanged = Notification.Name("toggleSidebarShortcutChanged")
}

public enum UserDefaultsKeys {
    public static let defaultBrowserBundleId = "defaultBrowserBundleId"
    public static let alwaysOnTopEnabled = "alwaysOnTopEnabled"
    public static let lastSelectedWorkspaceId = "lastSelectedWorkspaceId"
    public static let mainWindowFrame = "mainWindowFrame"
    public static let sidebarAttachmentEnabled = "sidebarAttachmentEnabled"
    public static let sidebarPosition = "sidebarPosition"
    public static let toggleSidebarShortcut = "toggleSidebarShortcut"
}
