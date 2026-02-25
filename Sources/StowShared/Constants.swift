import Foundation
#if canImport(AppKit)
import AppKit
#endif

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

#if canImport(AppKit)
public let nodePasteboardType = NSPasteboard.PasteboardType("com.stow.node")
public let workspacePasteboardType = NSPasteboard.PasteboardType("com.stow.workspace")
#endif

#if os(macOS)
public struct LayoutConstants {
    public static let windowPadding: CGFloat = 8
}

public struct ListMetrics {
    public let rowHeight: CGFloat = 40
    public let verticalGap: CGFloat = 4
    public let leftPadding: CGFloat = 8
    public let iconSize: CGFloat = 20
    public let indentWidth: CGFloat = 16
    public let rowCornerRadius: CGFloat = 12
    public let iconCornerRadius: CGFloat = 4
    public let linkTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    public let folderTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    public let titleColor: NSColor = NSColor.black.withAlphaComponent(0.8)
    public let hoverBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.1)
    public let selectedBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.2)
    public let deleteTintColor: NSColor = NSColor.black.withAlphaComponent(0.5)
    public let iconTintColor: NSColor = NSColor.black.withAlphaComponent(0.7)

    public init() {}
}
#endif
