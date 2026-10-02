import AppKit

public let nodePasteboardType = NSPasteboard.PasteboardType("com.stow.node")
public let workspacePasteboardType = NSPasteboard.PasteboardType("com.stow.workspace")

public struct LayoutConstants {
    public static let windowPadding: CGFloat = 8
}

/// Row geometry, type and colors for the node list, all resolved from `StowTheme`.
public struct ListMetrics {
    public var density: StowTheme.Density = .compact
    public var colors: StowTheme.Colors

    public var rowHeight: CGFloat { StowTheme.List.rowHeight(density) }
    public let verticalGap: CGFloat = StowTheme.List.rowGap
    public let leftPadding: CGFloat = StowTheme.List.horizontalInset
    public let iconSize: CGFloat = StowTheme.List.glyphSize
    public let indentWidth: CGFloat = StowTheme.List.indent
    public let disclosureWidth: CGFloat = StowTheme.List.disclosureWidth
    public let actionSlot: CGFloat = StowTheme.List.actionSlot
    public let rowCornerRadius: CGFloat = StowTheme.List.rowRadius
    public let iconCornerRadius: CGFloat = StowTheme.List.glyphRadius
    public var linkTitleFont: NSFont { StowTheme.Font.row }
    public var folderTitleFont: NSFont { StowTheme.Font.rowEmphasized }

    public var titleColor: NSColor { colors.inkPrimary }
    public var secondaryColor: NSColor { colors.inkSecondary }
    public var iconTintColor: NSColor { colors.inkSecondary }
    public var hoverBackgroundColor: NSColor { colors.hover }
    public var selectedBackgroundColor: NSColor { colors.multiSelected }

    public init(colors: StowTheme.Colors = StowTheme.colors(for: .defaultColor())) {
        self.colors = colors
    }
}

extension NSView {
    /// Resolves a dynamic color against this view's appearance, for use on CALayers.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}
