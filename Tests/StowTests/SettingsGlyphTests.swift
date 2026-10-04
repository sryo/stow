import XCTest
@testable import StowCore

/// Settings has one icon everywhere: the title-row button and the rail's gear draw the
/// same system symbol.
@MainActor
final class SettingsGlyphTests: XCTestCase {
    func testRailGearUsesTheSettingsSymbol() {
        XCTAssertEqual(RailGlyphButton.symbolName(for: .gear), StowSymbols.settings)
    }

    func testSettingsSymbolExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: StowSymbols.settings, accessibilityDescription: nil))
    }
}
