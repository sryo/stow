import XCTest
@testable import StowShared

final class ClipboardImportParserTests: XCTestCase {

    func testEmptyClipboard() {
        XCTAssertEqual(ClipboardImportParser.parse(""), [])
        XCTAssertEqual(ClipboardImportParser.parse("   \n  \t  "), [])
    }

    // MARK: - Tasks

    func testTask_uncheckedBoxWithDashPrefix() {
        let items = ClipboardImportParser.parse("- [ ] Buy milk")
        XCTAssertEqual(items, [.task(title: "Buy milk", isCompleted: false)])
    }

    func testTask_checkedBox() {
        let items = ClipboardImportParser.parse("- [x] Sent email")
        XCTAssertEqual(items, [.task(title: "Sent email", isCompleted: true)])
    }

    func testTask_uppercaseCheckmark() {
        let items = ClipboardImportParser.parse("- [X] Done")
        XCTAssertEqual(items, [.task(title: "Done", isCompleted: true)])
    }

    func testTask_withoutDashPrefix() {
        let items = ClipboardImportParser.parse("[ ] Just brackets")
        XCTAssertEqual(items, [.task(title: "Just brackets", isCompleted: false)])
    }

    // MARK: - Links

    func testLink_bareHttpsUrl() {
        let items = ClipboardImportParser.parse("https://example.com/path")
        XCTAssertEqual(items.count, 1)
        guard case .link(let url, let title) = items[0] else { XCTFail(); return }
        XCTAssertEqual(url.absoluteString, "https://example.com/path")
        XCTAssertEqual(title, "example.com")
    }

    func testLink_localhostWithPort() {
        // Mac handled localhost; iOS used to treat it as a snippet. The shared
        // parser brings both platforms onto the Mac behavior.
        let items = ClipboardImportParser.parse("localhost:3000")
        XCTAssertEqual(items.count, 1)
        guard case .link(let url, _) = items[0] else { XCTFail("Expected link, got \(items)"); return }
        XCTAssertEqual(url.absoluteString, "http://localhost:3000")
    }

    func testLink_localhostWithPath() {
        let items = ClipboardImportParser.parse("localhost:3000/dashboard")
        guard case .link(let url, _) = items.first else { XCTFail(); return }
        XCTAssertEqual(url.absoluteString, "http://localhost:3000/dashboard")
    }

    func testLink_stripsTrailingPunctuation() {
        let items = ClipboardImportParser.parse("Check this: https://example.com.")
        guard case .link(let url, _) = items.first else { XCTFail(); return }
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testLink_multipleUrlsOneLine() {
        let items = ClipboardImportParser.parse("See https://a.test and https://b.test for more")
        XCTAssertEqual(items.count, 2)
    }

    func testLink_titleIsHostNotFullUrl() {
        let items = ClipboardImportParser.parse("https://www.example.com/very/long/path?q=x")
        guard case .link(_, let title) = items.first else { XCTFail(); return }
        XCTAssertEqual(title, "www.example.com", "Title is the raw host — caller renders via Link.displayDomain to strip www")
    }

    // MARK: - Snippets

    func testSnippet_singleLine() {
        let items = ClipboardImportParser.parse("Just a note, no URL")
        XCTAssertEqual(items, [.snippet(title: "Just a note, no URL", content: "Just a note, no URL")])
    }

    func testSnippet_multiLineUsesFirstLineAsTitleCapped() {
        let long = String(repeating: "x", count: 80)
        let items = ClipboardImportParser.parse("\(long)\nline 2")
        guard case .snippet(let title, let content) = items.first else { XCTFail(); return }
        XCTAssertEqual(title, String(repeating: "x", count: 50) + "…")
        XCTAssertEqual(content, "\(long)\nline 2")
    }

    func testSnippet_skipsBlankLinesInTrim() {
        // Blank lines inside the snippet should be preserved in content,
        // but leading/trailing blank lines are dropped because the loop
        // skips empty trimmed lines.
        let items = ClipboardImportParser.parse("first\nsecond")
        guard case .snippet(let title, let content) = items.first else { XCTFail(); return }
        XCTAssertEqual(title, "first")
        XCTAssertEqual(content, "first\nsecond")
    }

    // MARK: - Mixed

    func testMixed_taskLinkSnippetInOrder() {
        let pasted = """
        - [ ] Reply to bug report
        https://github.com/x/y/issues/123
        random thoughts about the week
        another line
        """
        let items = ClipboardImportParser.parse(pasted)
        XCTAssertEqual(items.count, 3)
        guard case .task(let title, _) = items[0] else { XCTFail("first item should be a task"); return }
        XCTAssertEqual(title, "Reply to bug report")
        guard case .link = items[1] else { XCTFail("second should be link"); return }
        guard case .snippet = items[2] else { XCTFail("third should be snippet"); return }
    }
}
