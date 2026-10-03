import XCTest
@testable import StowShared

final class DockIconTintTests: XCTestCase {

    private let tileTop = StowTheme.RGB(hex: "#2A2A2E")!

    func testPresetsKeepTheirOwnColor() {
        for colorId in WorkspaceColorId.allCases where colorId != .settingsBackground {
            XCTAssertEqual(DockIconTint.ribbonColor(for: colorId), StowTheme.RGB(colorId.color), "\(colorId)")
        }
    }

    func testSettingsUsesTheBundledIcon() {
        XCTAssertNil(DockIconTint.ribbonColor(for: .settingsBackground))
    }

    func testEveryCustomColorReadsOnTheTile() {
        let steps: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        for r in steps { for g in steps { for b in steps {
            let hex = StowTheme.RGB(r, g, b).hex
            let ribbon = DockIconTint.ribbonColor(for: .custom(hex))!
            XCTAssertGreaterThanOrEqual(ribbon.contrast(with: tileTop), 3, hex)
        }}}
    }

    func testDarkCustomColorKeepsItsHue() {
        let ribbon = DockIconTint.ribbonColor(for: .custom("#1A237E"))!
        XCTAssertGreaterThan(ribbon.b, ribbon.r)
        XCTAssertGreaterThan(ribbon.b, ribbon.g)
    }
}
