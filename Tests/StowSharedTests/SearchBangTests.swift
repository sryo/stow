import XCTest
@testable import StowShared

/// "!g term" in the search field opens a web search on Return; "!doc" alone makes a new doc.
final class SearchBangTests: XCTestCase {

    func testABangBeforeTheTermsSearchesThatSite() {
        XCTAssertEqual(SearchBang.url(for: "!g swift actors")?.absoluteString,
                       "https://www.google.com/search?q=swift%20actors")
    }

    func testABangAfterTheTermsWorksToo() {
        XCTAssertEqual(SearchBang.url(for: "rust book !ddg")?.absoluteString,
                       "https://duckduckgo.com/?q=rust%20book")
    }

    func testTermsAreEscaped() {
        XCTAssertEqual(SearchBang.url(for: "!g a&b=c")?.absoluteString,
                       "https://www.google.com/search?q=a%26b%3Dc")
    }

    func testAQuickCreateBangOpensTheNewPage() {
        XCTAssertEqual(SearchBang.url(for: "!doc")?.absoluteString, "https://docs.new")
        XCTAssertEqual(SearchBang.url(for: "!sheet")?.absoluteString, "https://sheets.new")
    }

    func testASearchBangWithoutTermsDoesNothing() {
        XCTAssertNil(SearchBang.url(for: "!g"))
    }

    func testAnUnknownBangOrPlainQueryDoesNothing() {
        XCTAssertNil(SearchBang.url(for: "!nope thing"))
        XCTAssertNil(SearchBang.url(for: "plain query"))
        XCTAssertNil(SearchBang.url(for: "hello!"))
    }
}
