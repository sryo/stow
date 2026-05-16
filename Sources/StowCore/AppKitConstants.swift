import AppKit

public let nodePasteboardType = NSPasteboard.PasteboardType("com.stow.node")
public let workspacePasteboardType = NSPasteboard.PasteboardType("com.stow.workspace")

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
