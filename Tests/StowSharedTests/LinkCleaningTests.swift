import XCTest
@testable import StowShared

/// Tracking parameters (utm_*, fbclid…) don't make a different page: they're stripped
/// when a link is saved and ignored when matching links to tabs.
final class LinkCleaningTests: XCTestCase {

    func testTrackingParametersAreStripped() {
        XCTAssertEqual(
            URLCanonical.cleaned("https://example.com/post?utm_source=x&id=7&fbclid=abc&utm_medium=email"),
            "https://example.com/post?id=7"
        )
    }

    func testAURLWithOnlyTrackingLosesItsQuestionMark() {
        XCTAssertEqual(URLCanonical.cleaned("https://example.com/a?gclid=1&utm_campaign=z"), "https://example.com/a")
    }

    func testAURLWithoutTrackingIsLeftExactlyAsIs() {
        let url = "https://Example.com/a?b=1&a=2#frag"
        XCTAssertEqual(URLCanonical.cleaned(url), url)
    }

    func testAStringThatIsNotAURLIsLeftAlone() {
        XCTAssertEqual(URLCanonical.cleaned("not a url ?utm_source=x"), "not a url ?utm_source=x")
    }

    func testATabWithTrackingMatchesTheSavedLink() {
        XCTAssertEqual(URLCanonical.key("https://example.com/post?utm_source=news"), URLCanonical.key("https://example.com/post"))
    }

    func testSavingALinkStoresItClean() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: DataStore(baseDirectory: dir))

        let stowed = model.stowLink(url: URL(string: "https://a.test/x?utm_source=feed")!, title: "x", workspaceId: nil)
        let added = model.addLink(urlString: "https://b.test/y?fbclid=1&q=2", title: "y", parentId: nil)

        guard case .added(let stowedId) = stowed,
              case .link(let first)? = model.nodeById(stowedId),
              case .link(let second)? = model.nodeById(added) else { return XCTFail() }
        XCTAssertEqual(first.url, "https://a.test/x")
        XCTAssertEqual(second.url, "https://b.test/y?q=2")
        XCTAssertEqual(model.stowLink(url: URL(string: "https://a.test/x?utm_medium=mail")!, title: "x", workspaceId: nil),
                       .alreadyPresent(stowedId))
    }
}
