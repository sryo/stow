import XCTest
@testable import StowShared

/// Which open tab a saved link should bring forward: the same page first; then the same
/// path when the tab still has the link's query; then the same specific path whatever its
/// query, since apps keep view state there (selection, zoom, share tokens).
final class URLMatchTests: XCTestCase {
    private func score(_ saved: String, _ open: String) -> Int? {
        URLMatch.score(saved: URL(string: saved)!, open: URL(string: open)!)
    }

    func testTheSamePageIsTheBestMatch() {
        XCTAssertEqual(score("https://example.com/a/b?x=1", "https://EXAMPLE.com/a/b?x=1#top"), URLMatch.samePage)
    }

    func testATabThatKeptTheLinksQueryMatches() {
        XCTAssertEqual(score("https://example.com/watch?v=7", "https://example.com/watch?v=7&t=42"), URLMatch.sameQuery)
    }

    func testASpecificPathMatchesWhateverItsViewState() {
        XCTAssertEqual(score("https://www.figma.com/design/HP8r/Untitled?node-id=16-554&t=8f",
                             "https://www.figma.com/design/HP8r/Untitled?node-id=40-2&t=zz"), URLMatch.samePath)
    }

    func testAGenericPathNeedsTheQuery() {
        XCTAssertNil(score("https://youtube.com/watch?v=A", "https://youtube.com/watch?v=B"))
        XCTAssertNil(score("https://google.com/search?q=swift", "https://google.com/search?q=rust"))
    }

    func testOtherPagesAndSitesDoNotMatch() {
        XCTAssertNil(score("https://example.com/a/b", "https://example.com/a/c"))
        XCTAssertNil(score("https://example.com/a/b", "https://other.com/a/b"))
    }

    func testWwwAndATrailingSlashDoNotMatter() {
        XCTAssertEqual(score("https://github.com/sryo/stow", "https://www.github.com/sryo/stow/"), URLMatch.samePage)
    }

    func testTheBestRankedTabWins() {
        let saved = URL(string: "https://example.com/doc/42?view=1")!
        let tabs = ["https://example.com/doc/42?view=9", "https://example.com/doc/42?view=1", "https://example.com/other"]
            .map { URL(string: $0)! }
        XCTAssertEqual(URLMatch.best(for: saved, among: tabs, url: { $0 }), tabs[1])
    }
}
