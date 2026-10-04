import AppKit
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

    // MARK: - tab listing scripts

    private let supportedBrowsers = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.apple.Safari",
    ]

    /// One unreadable tab (Arc's empty or special tabs have no URL) must not abort the
    /// whole listing, or every link opens a duplicate instead of focusing its tab.
    func testTabListScripts_skipTabsThatCannotBeRead() {
        for bundleId in supportedBrowsers {
            guard let source = BrowserTabService.tabListScript(bundleId: bundleId) else {
                return XCTFail("no script for \(bundleId)")
            }
            XCTAssertTrue(source.contains("try"), "\(bundleId) reads tabs without try")
            XCTAssertTrue(source.contains("end try"), bundleId)
            // Terms like `tabs` come from the browser's dictionary, so only installed ones compile.
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil else { continue }
            var error: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false,
                          "\(bundleId) script does not compile: \(String(describing: error))")
        }
    }

    func testTabListScript_unknownBrowserIsNil() {
        XCTAssertNil(BrowserTabService.tabListScript(bundleId: "org.mozilla.firefox"))
    }

    /// Runs only with STOW_LIVE_BROWSER_TESTS=1 and a supported browser open: the listing
    /// must return tabs from every running browser.
    func testListTabs_liveBrowserReturnsTabs() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_LIVE_BROWSER_TESTS"] == "1")
        let tabs = BrowserTabService.listTabs()
        let running = supportedBrowsers.filter { BrowserManager.isRunning(bundleId: $0) }
        try XCTSkipIf(running.isEmpty, "no supported browser running")
        for bundleId in running {
            XCTAssertTrue(tabs.contains { $0.bundleId == bundleId }, "no tabs read from \(bundleId)")
        }
    }

    /// Runs only with STOW_LIVE_BROWSER_TESTS=1: opening a link whose page is already open
    /// focuses that tab instead of reporting a miss (which would open a duplicate). Uses
    /// each browser's current front tab, so no tab selection changes.
    func testFocusIfOpen_liveFindsOpenTabInEachBrowser() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_LIVE_BROWSER_TESTS"] == "1")
        let running = supportedBrowsers.filter { BrowserManager.isRunning(bundleId: $0) }
        try XCTSkipIf(running.isEmpty, "no supported browser running")
        for bundleId in running {
            guard let front = BrowserTabService.frontTab(bundleId: bundleId),
                  ["http", "https"].contains(front.url.scheme ?? "") else { continue }
            let focused = await BrowserTabService.focusIfOpen(url: front.url, onlyIn: bundleId)
            XCTAssertTrue(focused, "\(bundleId) did not focus its open tab \(front.url)")
        }
    }

    /// Runs only with STOW_LIVE_BROWSER_TESTS=1: focusing a tab that is NOT in front must
    /// succeed (a failed "raise window" step used to read as a miss and open a duplicate).
    /// Restores each browser's original front tab afterwards.
    func testFocus_liveSwitchesToBackgroundTabInEachBrowser() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_LIVE_BROWSER_TESTS"] == "1")
        let running = supportedBrowsers.filter { BrowserManager.isRunning(bundleId: $0) }
        try XCTSkipIf(running.isEmpty, "no supported browser running")
        let all = BrowserTabService.listTabs()
        for bundleId in running {
            guard let front = BrowserTabService.frontTab(bundleId: bundleId) else { continue }
            let mine = all.filter { $0.bundleId == bundleId }
            guard let original = mine.first(where: { $0.url == front.url }),
                  let other = mine.first(where: { $0.windowId == original.windowId && $0.url != front.url }) else { continue }
            XCTAssertTrue(BrowserTabService.focus(tab: other), "\(bundleId) failed to focus a background tab")
            XCTAssertEqual(BrowserTabService.frontTab(bundleId: bundleId)?.url, other.url, bundleId)
            XCTAssertTrue(BrowserTabService.focus(tab: original), "\(bundleId) failed to restore its front tab")
        }
    }

    /// Raising the window is best effort: Arc rejects `set index` while another app is in
    /// front, after the tab is already selected. That must not fail the focus, or the
    /// caller opens a duplicate tab.
    func testFocusScripts_raiseWindowIsBestEffort() {
        for bundleId in supportedBrowsers {
            let tab = OpenTab(bundleId: bundleId, windowId: "1", tabIndex: 2, url: URL(string: "https://example.com")!, title: "")
            guard let source = BrowserTabService.focusScript(tab: tab) else { return XCTFail("no focus script for \(bundleId)") }
            let lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let raise = lines.firstIndex(of: "set index to 1") else { return XCTFail("\(bundleId) never raises its window") }
            XCTAssertEqual(lines[raise - 1], "try", "\(bundleId) raises its window outside try")
            XCTAssertEqual(lines[raise + 1], "end try", bundleId)
        }
    }
}
