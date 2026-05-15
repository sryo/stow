import XCTest
@testable import StowCore

final class BrowserTabServiceTests: XCTestCase {

    // MARK: - canonicalize

    func testCanonicalize_lowercasesSchemeAndHost() {
        let a = URL(string: "HTTPS://Example.COM/path")!
        let b = URL(string: "https://example.com/path")!
        XCTAssertEqual(BrowserTabService.canonicalize(a), BrowserTabService.canonicalize(b))
    }

    func testCanonicalize_stripsFragment() {
        let withFragment = URL(string: "https://example.com/docs#section-2")!
        let withoutFragment = URL(string: "https://example.com/docs")!
        XCTAssertEqual(BrowserTabService.canonicalize(withFragment),
                       BrowserTabService.canonicalize(withoutFragment))
    }

    func testCanonicalize_emptyRootPathMatchesNoPath() {
        let trailing = URL(string: "https://example.com/")!
        let bare = URL(string: "https://example.com")!
        XCTAssertEqual(BrowserTabService.canonicalize(trailing),
                       BrowserTabService.canonicalize(bare))
    }

    func testCanonicalize_preservesQueryString() {
        // SPAs encode page identity in ?id=, ?tab=, etc. Don't conflate.
        let a = URL(string: "https://app.example.com/?view=settings")!
        let b = URL(string: "https://app.example.com/?view=billing")!
        XCTAssertNotEqual(BrowserTabService.canonicalize(a),
                          BrowserTabService.canonicalize(b))
    }

    func testCanonicalize_preservesNonRootPath() {
        let a = URL(string: "https://example.com/docs/intro")!
        let b = URL(string: "https://example.com/docs")!
        XCTAssertNotEqual(BrowserTabService.canonicalize(a),
                          BrowserTabService.canonicalize(b))
    }

    func testCanonicalize_differentHostsDoNotMatch() {
        // www. prefix preserved intentionally — folding it would conflate
        // sites that route differently between apex and www.
        let a = URL(string: "https://example.com/")!
        let b = URL(string: "https://www.example.com/")!
        XCTAssertNotEqual(BrowserTabService.canonicalize(a),
                          BrowserTabService.canonicalize(b))
    }

    // MARK: - parseRows

    func testParseRows_nilOutputReturnsEmpty() {
        XCTAssertEqual(BrowserTabService.parseRows(nil, bundleId: "com.x"), [])
    }

    func testParseRows_parsesWellFormedRows() {
        let output = "win1\t1\thttps://a.test/\tFirst\nwin1\t2\thttps://b.test/\tSecond\n"
        let tabs = BrowserTabService.parseRows(output, bundleId: "com.x")
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].windowId, "win1")
        XCTAssertEqual(tabs[0].tabIndex, 1)
        XCTAssertEqual(tabs[0].title, "First")
        XCTAssertEqual(tabs[1].url.absoluteString, "https://b.test/")
    }

    func testParseRows_titleAbsorbsEmbeddedTabs() {
        // A page titled "A\tB" must not split into 5 columns and get dropped.
        let output = "win1\t1\thttps://a.test/\tA\tB\n"
        let tabs = BrowserTabService.parseRows(output, bundleId: "com.x")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].title, "A\tB")
    }

    func testParseRows_skipsMalformed() {
        // URL(string:) is permissive (accepts most strings as relative URLs), so the
        // guard only catches: <4 columns AND non-numeric tabIndex.
        let output = """
        win1\t1\thttps://ok.test/\tOK
        win1\tNOT_A_NUMBER\thttps://x.test/\tBad index
        only_three\tcols\there
        win1\t3\thttps://ok2.test/\tOK2
        """
        let tabs = BrowserTabService.parseRows(output, bundleId: "com.x")
        XCTAssertEqual(tabs.map { $0.tabIndex }, [1, 3])
    }
}
