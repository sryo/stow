import XCTest
@testable import StowShared

/// The small cross-platform helpers every surface shares: the site letter tile,
/// the snippet language list and the reorder index math.
final class SharedHelpersTests: XCTestCase {

    // MARK: SiteGlyph

    func testHostDropsWWWAndCase() {
        XCTAssertEqual(SiteGlyph.host(of: "https://WWW.GitHub.com/sryo"), "github.com")
        XCTAssertEqual(SiteGlyph.host(of: "not a url"), "")
    }

    func testLettersMatchTheRailRule() {
        XCTAssertEqual(SiteGlyph.letters(title: "GitHub", host: "github.com"), "GH")
        XCTAssertEqual(SiteGlyph.letters(title: "linear", host: "linear.app"), "L")
        XCTAssertEqual(SiteGlyph.letters(title: "", host: "figma.com"), "F")
    }

    func testAssignLettersSplitsCollidingFirstLetters() {
        let linear = Link(id: UUID(), title: "Linear", url: "https://linear.app", faviconPath: nil)
        let linked = Link(id: UUID(), title: "Linkedin", url: "https://linkedin.com", faviconPath: nil)
        let letters = SiteGlyph.assignLetters([linear, linked])
        XCTAssertEqual(letters[linear.id], "Li")
        XCTAssertEqual(letters[linked.id], "Li")
        let alone = SiteGlyph.assignLetters([linear])
        XCTAssertEqual(alone[linear.id], SiteGlyph.letters(title: linear.title, host: SiteGlyph.host(of: linear.url)))
    }

    func testTileColorIsStablePerHostAndIgnoresWWW() {
        let a = SiteGlyph.tileRGB(for: SiteGlyph.host(of: "https://github.com"))
        let b = SiteGlyph.tileRGB(for: SiteGlyph.host(of: "https://www.github.com/x"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, SiteGlyph.tileRGB(for: "github.com"))
        XCTAssertNotEqual(SiteGlyph.tileRGB(for: "github.com"), SiteGlyph.tileRGB(for: "linear.app"))
    }

    // MARK: SnippetLanguage

    func testShellIsInTheSharedList() {
        XCTAssertTrue(SnippetLanguage.all.contains("Shell"))
        XCTAssertFalse(SnippetLanguage.all.contains("Bash"))
    }

    func testBashIsReadAsShell() {
        XCTAssertEqual(SnippetLanguage.normalized("Bash"), "Shell")
        XCTAssertEqual(SnippetLanguage.normalized("shell"), "Shell")
        XCTAssertEqual(SnippetLanguage.normalized("  "), nil)
        XCTAssertEqual(SnippetLanguage.normalized(nil), nil)
    }

    func testAnUnknownLanguageIsKeptAsAnExtraChoice() {
        XCTAssertEqual(SnippetLanguage.normalized("Elixir"), "Elixir")
        let choices = SnippetLanguage.choices(including: "Elixir")
        XCTAssertEqual(choices.last, "Elixir")
        XCTAssertEqual(choices.dropLast(), ArraySlice(SnippetLanguage.all))
        XCTAssertEqual(SnippetLanguage.choices(including: "Shell"), SnippetLanguage.all)
        XCTAssertEqual(SnippetLanguage.choices(including: nil), SnippetLanguage.all)
    }

    // MARK: ListReorder

    func testModelIndexSkipsItemsTheListDoesNotShow() {
        let archived = UUID(), a = UUID(), b = UUID(), c = UUID()
        let all = [archived, a, b, c]
        let visible = [a, b, c]
        // Drag c to the top of the visible list: it lands before a, after the hidden item.
        XCTAssertEqual(ListReorder.modelIndex(forSlot: 0, moving: c, visibleIds: visible, allIds: all), 1)
        // Drag a to the end.
        XCTAssertEqual(ListReorder.modelIndex(forSlot: 3, moving: a, visibleIds: visible, allIds: all), 4)
        // Dropping in place changes nothing.
        XCTAssertNil(ListReorder.modelIndex(forSlot: 1, moving: a, visibleIds: visible, allIds: all))
    }
}
