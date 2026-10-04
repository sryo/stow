import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Design tokens and the contrast solver behind every color Stow draws.
///
/// Colors are not stored as literals per view. Instead a `Palette` is derived from the
/// workspace color, the appearance and the tint mode, and each foreground is solved
/// against every surface it can land on (plain row, hovered row, multi-selected row):
///
/// - primary ink ≥ 7:1, secondary ink ≥ 5:1 (4.5 plus headroom), overdue ≥ 4.5:1
/// - accent, guides ≥ 3:1 against the surface (WCAG non-text)
///
/// If the chosen ink can't reach 7:1, the surface is nudged away from the ink until it
/// can. That is what makes arbitrary custom workspace colors safe.
public enum StowTheme {

    public enum Appearance: Sendable { case light, dark }

    /// How much of the workspace color the window shows.
    public enum TintMode: String, Codable, CaseIterable, Sendable {
        /// The workspace color is the window background.
        case full
        /// A light wash of the workspace color over a neutral surface.
        case subtle
        /// Neutral surface; the hue appears only in the workspace dot.
        case off
    }

    /// The user's tint preference. Full is the default.
    public static var preferredTint: TintMode {
        get { UserDefaults.standard.string(forKey: "StowTintMode").flatMap(TintMode.init(rawValue:)) ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "StowTintMode") }
    }

    // MARK: - Color math

    /// An sRGB color with components in 0...1.
    public struct RGB: Equatable, Sendable {
        public var r: Double, g: Double, b: Double

        public init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = min(max(r, 0), 1)
            self.g = min(max(g, 0), 1)
            self.b = min(max(b, 0), 1)
        }

        public init?(hex: String) {
            let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }

        public init(_ color: PlatformColor) {
            #if canImport(AppKit)
            let c = color.usingColorSpace(.sRGB) ?? color
            self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
            #else
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.init(Double(r), Double(g), Double(b))
            #endif
        }

        public var hex: String {
            String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        /// WCAG 2 relative luminance.
        public var luminance: Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        public func contrast(with other: RGB) -> Double {
            let a = luminance, b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Linear blend in sRGB space: `t = 0` is self, `t = 1` is `other`.
        public func mix(_ other: RGB, _ t: Double) -> RGB {
            RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }

        public var platformColor: PlatformColor {
            PlatformColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        }

        public static let black = RGB(0, 0, 0)
        public static let white = RGB(1, 1, 1)
    }

    // MARK: - Fixed tokens

    enum Seed {
        static let inkDark = RGB(hex: "#1C1C1E")!
        static let inkLight = RGB(hex: "#F5F5F7")!
        static let neutralLight = RGB(hex: "#F4F4F6")!
        static let neutralDark = RGB(hex: "#1C1C1F")!
        static let settingsLight = RGB(hex: "#F2F2F4")!
        static let settingsDark = RGB(hex: "#232326")!
        static let raisedLight = RGB(hex: "#FFFFFF")!
        static let raisedDark = RGB(hex: "#2C2C30")!
        /// Selection is a dark fill with white text on light surfaces, and a light fill
        /// with dark text on dark surfaces, so it always separates from the surface.
        static let selectionOnLight = RGB(hex: "#004FBD")!
        static let selectionOnDark = RGB(hex: "#8CC4FF")!
        static let accentOnLight = RGB(hex: "#004FBD")!
        static let accentOnDark = RGB(hex: "#8CC4FF")!
        static let overdueOnLight = RGB(hex: "#B3261E")!
        static let overdueOnDark = RGB(hex: "#FFB4AB")!
        static let actionPrimary = RGB(hex: "#0A60D8")!
        static let actionArchive = RGB(hex: "#B25000")!
        static let actionDelete = RGB(hex: "#B42318")!

        /// Full tint in dark appearance keeps 30% of the workspace color over black.
        static let fullDarkKeep = 0.30
        static let subtleWash: [Appearance: Double] = [.light: 0.14, .dark: 0.12]
        /// Ink alpha used for hover and multi-select fills.
        static let hoverInk = 0.07
        static let multiInk = 0.10

        static let primaryTarget = 7.2
        static let secondaryTarget = 5.0
        static let overdueTarget = 4.6
        static let nonTextTarget = 3.0
    }

    // MARK: - Palette

    /// Fully resolved colors for one workspace color in one appearance.
    public struct Palette: Equatable, Sendable {
        public let surface: RGB
        public let hover: RGB
        public let multiSelected: RGB
        public let raised: RGB
        public let inkPrimary: RGB
        public let inkSecondary: RGB
        public let guide: RGB
        public let stroke: RGB
        public let accent: RGB
        public let selectionFill: RGB
        public let onSelection: RGB
        public let overdue: RGB
        /// Illustration paper: the workspace hue pushed toward the surface just far enough
        /// that primary ink stays >=4.5:1 and secondary ink >=3:1 on it.
        public let paper: RGB
        /// Halfway between surface and paper, for soft light like a flashlight beam.
        public let glow: RGB
        /// True when the ink is dark (light surface).
        public let inkIsDark: Bool

        /// Every surface a row's text can be drawn on.
        public var textSurfaces: [RGB] { [surface, hover, multiSelected] }
    }

    public static func palette(base: RGB, appearance: Appearance, tint: TintMode) -> Palette {
        let neutral = appearance == .light ? Seed.neutralLight : Seed.neutralDark
        let start: RGB
        switch tint {
        case .full:
            start = appearance == .light ? base : RGB.black.mix(base, Seed.fullDarkKeep)
        case .subtle:
            start = neutral.mix(base, Seed.subtleWash[appearance]!)
        case .off:
            start = neutral
        }
        return solve(surface: start, appearance: appearance, hue: base)
    }

    public static func settingsPalette(appearance: Appearance) -> Palette {
        solve(surface: appearance == .light ? Seed.settingsLight : Seed.settingsDark, appearance: appearance, hue: nil)
    }

    private static func solve(surface start: RGB, appearance: Appearance, hue: RGB?) -> Palette {
        let inkIsDark: Bool
        if appearance == .dark {
            inkIsDark = Seed.inkDark.contrast(with: start) > Seed.inkLight.contrast(with: start) * 1.5
        } else {
            inkIsDark = Seed.inkDark.contrast(with: start) >= Seed.inkLight.contrast(with: start)
        }
        let ink = inkIsDark ? Seed.inkDark : Seed.inkLight
        let away = inkIsDark ? RGB.white : RGB.black

        func surfaces(_ s: RGB) -> [RGB] { [s, s.mix(ink, Seed.hoverInk), s.mix(ink, Seed.multiInk)] }
        func minContrast(_ fg: RGB, _ list: [RGB]) -> Double { list.map { fg.contrast(with: $0) }.min()! }

        var surface = start
        for _ in 0..<100 where minContrast(ink, surfaces(surface)) < Seed.primaryTarget {
            surface = surface.mix(away, 0.03)
        }
        let list = surfaces(surface)

        // Fade toward the surface as far as the target allows, so secondary reads as secondary.
        func faded(_ target: Double, against: [RGB]) -> RGB {
            var t = 0.7
            while t > 0 {
                let c = ink.mix(surface, t)
                if minContrast(c, against) >= target { return c }
                t -= 0.01
            }
            return ink
        }
        // Push a hued color toward the ink until it clears the target.
        func strengthened(_ color: RGB, _ target: Double, against: [RGB]) -> RGB {
            var t = 0.0
            while t <= 1 {
                let c = color.mix(ink, t)
                if minContrast(c, against) >= target { return c }
                t += 0.02
            }
            return ink
        }

        // Paper starts from the hue (lightened when the ink is dark) and backs off toward
        // the surface until both inks read on it.
        let paperSource = hue.map { inkIsDark ? RGB.white.mix($0, 0.35) : $0 } ?? (inkIsDark ? RGB.white : RGB.black)
        var paper = surface
        var t = 0.6
        while t > 0 {
            let candidate = surface.mix(paperSource, t)
            if ink.contrast(with: candidate) >= 4.5 && faded(Seed.secondaryTarget, against: list).contrast(with: candidate) >= 3 {
                paper = candidate
                break
            }
            t -= 0.02
        }

        let selectionFill = strengthened(inkIsDark ? Seed.selectionOnLight : Seed.selectionOnDark, Seed.nonTextTarget, against: [surface])
        let onSelection = inkIsDark ? RGB.white : Seed.inkDark
        return Palette(
            surface: surface,
            hover: list[1],
            multiSelected: list[2],
            raised: appearance == .light ? Seed.raisedLight : Seed.raisedDark,
            inkPrimary: ink,
            inkSecondary: faded(Seed.secondaryTarget, against: list),
            guide: faded(Seed.nonTextTarget, against: [surface]),
            stroke: ink.mix(surface, 0.86),
            accent: strengthened(inkIsDark ? Seed.accentOnLight : Seed.accentOnDark, Seed.nonTextTarget, against: [surface]),
            selectionFill: selectionFill,
            onSelection: onSelection,
            overdue: strengthened(inkIsDark ? Seed.overdueOnLight : Seed.overdueOnDark, Seed.overdueTarget, against: list),
            paper: paper,
            glow: surface.mix(paper, 0.5),
            inkIsDark: inkIsDark
        )
    }

    // MARK: - Layout

    public enum List {
        public static let rowHeight: CGFloat = 28
        public static let rowGap: CGFloat = 0
        public static let horizontalInset: CGFloat = 8
        public static let indent: CGFloat = 16
        public static let disclosureWidth: CGFloat = 14
        public static let glyphSize: CGFloat = 16
        public static let glyphToTitle: CGFloat = 7
        public static let actionSlot: CGFloat = 18
        public static let rowRadius: CGFloat = 6
        public static let glyphRadius: CGFloat = 4
    }

    public enum Chrome {
        public static let titleBarHeight: CGFloat = 38
        public static let searchHeight: CGFloat = 36
        public static let bottomBarHeight: CGFloat = 40
        public static let fieldRadius: CGFloat = 8
        public static let sheetRadius: CGFloat = 12
        public static let pageIndicatorDot: CGFloat = 6
    }

    // MARK: - Type

    /// The macOS type ramp. iOS maps the same roles to Dynamic Type styles.
    public enum Font {
        public static var row: PlatformFont { .systemFont(ofSize: 13, weight: .regular) }
        public static var rowEmphasized: PlatformFont { .systemFont(ofSize: 13, weight: .semibold) }
        public static var meta: PlatformFont { .systemFont(ofSize: 11, weight: .medium) }
        public static var badge: PlatformFont { .monospacedSystemFont(ofSize: 10, weight: .semibold) }
        public static var section: PlatformFont { .systemFont(ofSize: 11, weight: .semibold) }
        public static var control: PlatformFont { .systemFont(ofSize: 12, weight: .medium) }
        public static var field: PlatformFont { .systemFont(ofSize: 13, weight: .regular) }
        public static var title: PlatformFont { .systemFont(ofSize: 13, weight: .semibold) }
        public static var keycap: PlatformFont { .monospacedSystemFont(ofSize: 10, weight: .semibold) }
        public static var emptyTitle: PlatformFont { .systemFont(ofSize: 14, weight: .semibold) }
        public static var emptyBody: PlatformFont { .systemFont(ofSize: 12, weight: .regular) }
        public static var code: PlatformFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    }

    /// Attributes for a one-line label set through an attributed string. Setting
    /// `attributedStringValue` replaces the field's own line break mode, so the attributed
    /// string has to carry truncation itself or the text wraps.
    public static func singleLineAttributes(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var result = attributes
        result[.paragraphStyle] = style
        return result
    }

    public enum Motion {
        public static let fast: TimeInterval = 0.15
        public static let normal: TimeInterval = 0.2
        public static let slow: TimeInterval = 0.3
        public static let springLoadDelay: TimeInterval = 0.6
        public static let toastDuration: TimeInterval = 6
    }
}

// MARK: - Dynamic platform colors

extension StowTheme {

    /// Appearance-aware colors for one workspace color. Each property resolves to the
    /// light or dark palette at draw time, so views get dark mode for free.
    public struct Colors: Sendable {
        public let light: Palette
        public let dark: Palette

        public init(light: Palette, dark: Palette) {
            self.light = light
            self.dark = dark
        }

        public var surface: PlatformColor { dynamic(\.surface) }
        public var hover: PlatformColor { dynamic(\.hover) }
        public var multiSelected: PlatformColor { dynamic(\.multiSelected) }
        public var raised: PlatformColor { dynamic(\.raised) }
        public var inkPrimary: PlatformColor { dynamic(\.inkPrimary) }
        public var inkSecondary: PlatformColor { dynamic(\.inkSecondary) }
        public var guide: PlatformColor { dynamic(\.guide) }
        public var stroke: PlatformColor { dynamic(\.stroke) }
        public var accent: PlatformColor { dynamic(\.accent) }
        public var selectionFill: PlatformColor { dynamic(\.selectionFill) }
        public var onSelection: PlatformColor { dynamic(\.onSelection) }
        public var overdue: PlatformColor { dynamic(\.overdue) }
        public var paper: PlatformColor { dynamic(\.paper) }
        public var glow: PlatformColor { dynamic(\.glow) }

        public static var actionPrimary: PlatformColor { Seed.actionPrimary.platformColor }
        public static var actionArchive: PlatformColor { Seed.actionArchive.platformColor }
        public static var actionDelete: PlatformColor { Seed.actionDelete.platformColor }

        public func palette(_ appearance: Appearance) -> Palette {
            appearance == .light ? light : dark
        }

        private func dynamic(_ key: KeyPath<Palette, RGB>) -> PlatformColor {
            let l = light[keyPath: key].platformColor
            let d = dark[keyPath: key].platformColor
            #if canImport(AppKit)
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
            }
            #else
            return UIColor { $0.userInterfaceStyle == .dark ? d : l }
            #endif
        }
    }

    public static func colors(for colorId: WorkspaceColorId, tint: TintMode = .full) -> Colors {
        if colorId == .settingsBackground {
            return Colors(light: settingsPalette(appearance: .light), dark: settingsPalette(appearance: .dark))
        }
        let base = RGB(colorId.color)
        return Colors(
            light: palette(base: base, appearance: .light, tint: tint),
            dark: palette(base: base, appearance: .dark, tint: tint)
        )
    }
}
