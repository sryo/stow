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

/// Appearance-aware colors for Settings and its controls, from the settings palette.
enum SettingsColors {
    static let palette = StowTheme.colors(for: .settingsBackground)
    static var ink: NSColor { palette.inkPrimary }
    static var inkSecondary: NSColor { palette.inkSecondary }
    /// Resting fill for fields, buttons and the off toggle track.
    static var fill: NSColor { palette.hover }
    static var fillStrong: NSColor { palette.multiSelected }
    static var stroke: NSColor { palette.stroke }
    static var selection: NSColor { palette.selectionFill }
    static var onSelection: NSColor { palette.onSelection }
    static var raised: NSColor { palette.raised }
    static var accent: NSColor { palette.accent }
    static var success: NSColor { dynamic(light: "#1B7F3B", dark: "#5BD68A") }
    static var danger: NSColor { dynamic(light: "#B42318", dark: "#FF9B8F") }

    private static func dynamic(light: String, dark: String) -> NSColor {
        let l = StowTheme.RGB(hex: light)!.platformColor
        let d = StowTheme.RGB(hex: dark)!.platformColor
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }
}
