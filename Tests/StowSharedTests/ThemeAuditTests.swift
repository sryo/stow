import XCTest
@testable import StowShared

/// Contrast audit for every derived palette. Each surface a row's text can land on
/// (plain, hovered, multi-selected) is measured against every foreground that can be
/// drawn there, for all presets, both appearances and every tint mode.
final class ThemeAuditTests: XCTestCase {

    private let appearances: [StowTheme.Appearance] = [.light, .dark]

    /// A coarse grid over the whole sRGB cube stands in for arbitrary custom colors.
    private var customGrid: [StowTheme.RGB] {
        let steps: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        return steps.flatMap { r in steps.flatMap { g in steps.map { b in StowTheme.RGB(r, g, b) } } }
    }

    private var presets: [StowTheme.RGB] {
        WorkspaceColorId.allCases.map { StowTheme.RGB($0.color) }
    }

    private func assertPasses(_ base: StowTheme.RGB, _ appearance: StowTheme.Appearance, _ tint: StowTheme.TintMode,
                              file: StaticString = #filePath, line: UInt = #line) {
        let p = StowTheme.palette(base: base, appearance: appearance, tint: tint)
        let surfaces = p.textSurfaces
        let label = "\(base.hex) \(appearance) \(tint)"

        let primary = surfaces.map { p.inkPrimary.contrast(with: $0) }.min()!
        let secondary = surfaces.map { p.inkSecondary.contrast(with: $0) }.min()!
        let overdue = surfaces.map { p.overdue.contrast(with: $0) }.min()!
        XCTAssertGreaterThanOrEqual(primary, 7, "primary \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(secondary, 4.5, "secondary \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(overdue, 4.5, "overdue \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.onSelection.contrast(with: p.selectionFill), 7, "selection \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.accent.contrast(with: p.surface), 3, "accent \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.guide.contrast(with: p.surface), 3, "guide \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(p.selectionFill.contrast(with: p.surface), 3, "selection fill vs surface \(label)", file: file, line: line)
    }

    func testPresetsPassInEveryMode() {
        for base in presets {
            for appearance in appearances {
                for tint in StowTheme.TintMode.allCases {
                    assertPasses(base, appearance, tint)
                }
            }
        }
    }

    func testArbitraryCustomColorsAreGuarded() {
        for base in customGrid {
            for appearance in appearances {
                assertPasses(base, appearance, .full)
            }
        }
    }

    func testSettingsPalettePasses() {
        for appearance in appearances {
            let p = StowTheme.settingsPalette(appearance: appearance)
            for s in p.textSurfaces {
                XCTAssertGreaterThanOrEqual(p.inkPrimary.contrast(with: s), 7)
                XCTAssertGreaterThanOrEqual(p.inkSecondary.contrast(with: s), 4.5)
            }
        }
    }

    func testFullTintKeepsPresetColorInLightMode() {
        // The workspace color should be the window, not a wash, unless contrast forces a nudge.
        for base in presets {
            let p = StowTheme.palette(base: base, appearance: .light, tint: .full)
            let drift = max(abs(p.surface.r - base.r), abs(p.surface.g - base.g), abs(p.surface.b - base.b))
            XCTAssertLessThanOrEqual(drift, 4.0 / 255, "\(base.hex) became \(p.surface.hex)")
        }
    }

    func testPresetsKeepSecondaryHeadroom() {
        // Secondary ink is solved to 5.0 so color-profile drift can't push it under 4.5.
        for base in presets {
            for appearance in appearances {
                let p = StowTheme.palette(base: base, appearance: appearance, tint: .full)
                let min = p.textSurfaces.map { p.inkSecondary.contrast(with: $0) }.min()!
                XCTAssertGreaterThanOrEqual(min, 4.95, "\(base.hex) \(appearance)")
            }
        }
    }

    func testContrastMath() {
        XCTAssertEqual(StowTheme.RGB(0, 0, 0).contrast(with: StowTheme.RGB(1, 1, 1)), 21, accuracy: 0.01)
        XCTAssertEqual(StowTheme.RGB(hex: "#777777")!.contrast(with: StowTheme.RGB(1, 1, 1)), 4.48, accuracy: 0.01)
    }

    func testListMetricsDensity() {
        // A 680pt-tall window minus chrome must fit at least 18 rows at default density.
        let chrome = StowTheme.Chrome.titleBarHeight + StowTheme.Chrome.searchHeight + StowTheme.Chrome.bottomBarHeight
        let rows = (680 - chrome) / (StowTheme.List.rowHeight(.compact) + StowTheme.List.rowGap)
        XCTAssertGreaterThanOrEqual(rows, 18)
        XCTAssertLessThanOrEqual(StowTheme.List.rowHeight(.compact), 30)
    }
}
