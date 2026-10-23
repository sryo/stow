import AppKit
import ScriptingBridge
import XCTest
@testable import StowCore

/// End to end against real browsers (STOW_LIVE_BROWSER_TESTS=1): a page opened in each
/// browser is found among its tabs and, once another page covers it, focused again
/// instead of opened twice. Every tab it opens carries a marker and is closed after.
final class BrowserTabLiveTests: XCTestCase {
    private static let browsers = [
        (bundleId: "com.google.Chrome.canary", appName: "Google Chrome Canary"),
        (bundleId: "company.thebrowser.Browser", appName: "Arc"),
        (bundleId: "com.apple.Safari", appName: "Safari"),
    ]
    private let marker = "stow-live-\(UUID().uuidString.prefix(8))"

    override func tearDown() {
        for browser in Self.browsers where BrowserManager.isRunning(bundleId: browser.bundleId) {
            closeMarkedTabs(appName: browser.appName)
        }
    }

    func testAnOpenPageIsFoundAndFocusedInEachBrowser() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_LIVE_BROWSER_TESTS"] == "1")
        for browser in Self.browsers where NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId) != nil {
            let saved = URL(string: "https://example.com/?\(marker)=saved")!
            let cover = URL(string: "https://example.org/?\(marker)=cover")!

            BrowserManager.open(url: saved, bundleId: browser.bundleId)
            let listed = await waitFor { BrowserTabService.listTabs().contains { $0.url == saved } }
            XCTAssertTrue(listed, "\(browser.appName): the opened page never showed up among its tabs")

            BrowserManager.open(url: cover, bundleId: browser.bundleId)
            let covered = await waitFor { BrowserTabService.frontTab(bundleId: browser.bundleId)?.url == cover }
            XCTAssertTrue(covered, "\(browser.appName): the second page never came to the front")

            let focused = await BrowserTabService.focusIfOpen(url: saved, onlyIn: browser.bundleId)
            XCTAssertTrue(focused, "\(browser.appName): an open page was reported missing, so it would open twice")
            let front = await waitFor { BrowserTabService.frontTab(bundleId: browser.bundleId)?.url == saved }
            XCTAssertTrue(front, "\(browser.appName): focusing didn't bring the open page to the front")
        }
    }

    private func waitFor(_ seconds: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return condition()
    }

    private func closeMarkedTabs(appName: String) {
        let source = """
        tell application "\(appName)"
            repeat with w in windows
                repeat with i from (count of tabs of w) to 1 by -1
                    try
                        if (URL of tab i of w) contains "\(marker)" then close tab i of w
                    end try
                end repeat
            end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // Headless copies of the browser can capture AppleScript; close in the windowed one too.
        for app in NSWorkspace.shared.runningApplications where app.localizedName == appName && app.activationPolicy == .regular {
            guard let bridge = SBApplication(processIdentifier: app.processIdentifier),
                  let windows = (bridge.value(forKey: "windows") as? SBElementArray)?.get() as? [SBObject] else { continue }
            for window in windows {
                guard let tabs = (window.value(forKey: "tabs") as? SBElementArray)?.get() as? [SBObject] else { continue }
                for tab in tabs.reversed() where (tab.value(forKey: "URL") as? String)?.contains(marker) == true {
                    _ = (tab as AnyObject).perform(NSSelectorFromString("close"))
                }
            }
        }
    }
}
