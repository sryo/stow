import AppKit

public let nodePasteboardType = NSPasteboard.PasteboardType("com.stow.node")
public let workspacePasteboardType = NSPasteboard.PasteboardType("com.stow.workspace")

public struct LayoutConstants {
    public static let windowPadding: CGFloat = 8
}

/// How much the window shows, chosen from its width ("Stow Elastic").
public enum ElasticMode: Equatable {
    /// Icons only; names appear on hover.
    case rail
    /// Titles without trailing metadata.
    case list
    /// The full sidebar.
    case sidebar
    /// A grid of tiles.
    case mosaic

    public static func forWidth(_ width: CGFloat) -> ElasticMode {
        switch width {
        case ..<120: return .rail
        case ..<260: return .list
        case ...560: return .sidebar
        default: return .mosaic
        }
    }

    public static let railWidth: CGFloat = 52
}

/// Row geometry, type and colors for the node list, all resolved from `StowTheme`.
public struct ListMetrics {
    public var density: StowTheme.Density = .compact
    public var mode: ElasticMode = .sidebar
    public var colors: StowTheme.Colors

    public var rowHeight: CGFloat { mode == .rail ? 42 : StowTheme.List.rowHeight(density) }
    public let verticalGap: CGFloat = StowTheme.List.rowGap
    /// Row inset to the glyph in list and sidebar (the Elastic mockup's 7pt).
    public let leftPadding: CGFloat = 7
    public let iconSize: CGFloat = StowTheme.List.glyphSize
    /// Folder children step in by 14pt; there are no disclosure chevrons or guides.
    public let indentWidth: CGFloat = 14
    public let disclosureWidth: CGFloat = StowTheme.List.disclosureWidth
    public let actionSlot: CGFloat = StowTheme.List.actionSlot
    public let rowCornerRadius: CGFloat = 7
    public let iconCornerRadius: CGFloat = StowTheme.List.glyphRadius
    public var linkTitleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
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
    static var surface: NSColor { palette.surface }
    /// Resting fill for hovered neutral rows.
    static var fill: NSColor { palette.hover }
    static var fillStrong: NSColor { palette.multiSelected }
    static var stroke: NSColor { palette.stroke }
    static var selection: NSColor { palette.selectionFill }
    static var onSelection: NSColor { palette.onSelection }
    static var raised: NSColor { palette.raised }
    static var accent: NSColor { palette.accent }
    /// Boundary of controls (segments, buttons, keycaps, dot rings): ink faded toward the
    /// surface only as far as 3:1 against both the surface and raised fills allows.
    static var edge: NSColor { solved(\.edge) }
    static var success: NSColor { solved(\.success) }
    static var danger: NSColor { palette.overdue }

    private struct Extra {
        let edge: StowTheme.RGB
        let success: StowTheme.RGB
    }

    private static let extraLight = extra(palette.light, successSeed: StowTheme.RGB(hex: "#1B7F3B")!)
    private static let extraDark = extra(palette.dark, successSeed: StowTheme.RGB(hex: "#5BD68A")!)

    private static func extra(_ p: StowTheme.Palette, successSeed: StowTheme.RGB) -> Extra {
        func minContrast(_ c: StowTheme.RGB, _ list: [StowTheme.RGB]) -> Double {
            list.map { c.contrast(with: $0) }.min() ?? 0
        }
        let edgeAgainst = p.textSurfaces + [p.raised]
        var edge = p.inkPrimary
        var t = 0.9
        while t > 0 {
            let candidate = p.inkPrimary.mix(p.surface, t)
            if minContrast(candidate, edgeAgainst) >= 3.0 { edge = candidate; break }
            t -= 0.01
        }
        var success = p.inkPrimary
        var s = 0.0
        while s <= 1 {
            let candidate = successSeed.mix(p.inkPrimary, s)
            if minContrast(candidate, p.textSurfaces) >= 4.6 { success = candidate; break }
            s += 0.02
        }
        return Extra(edge: edge, success: success)
    }

    private static func solved(_ key: KeyPath<Extra, StowTheme.RGB>) -> NSColor {
        let l = extraLight[keyPath: key].platformColor
        let d = extraDark[keyPath: key].platformColor
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l }
    }
}
