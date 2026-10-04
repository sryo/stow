import XCTest
@testable import StowCore

/// The Tabline follows the browser window through Accessibility notifications and only
/// falls back to a slow poll; with no browser running it doesn't poll at all.
@MainActor
final class TablineAXTests: XCTestCase {
    private let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome"]

    func testPollsWhileABrowserIsRunning() {
        XCTAssertTrue(TablineTracking.shouldPoll(running: ["com.apple.finder", "com.google.Chrome"], browsers: browsers))
    }

    func testDoesNotPollWithoutARunningBrowser() {
        XCTAssertFalse(TablineTracking.shouldPoll(running: ["com.apple.finder", nil, "com.apple.Terminal"], browsers: browsers))
        XCTAssertFalse(TablineTracking.shouldPoll(running: [], browsers: browsers))
        XCTAssertFalse(TablineTracking.shouldPoll(running: ["com.apple.Safari"], browsers: []))
    }

    func testFallbackPollIsSlow() {
        // Window moves arrive as notifications; the poll is only a safety net.
        XCTAssertGreaterThanOrEqual(TablineTracking.fallbackInterval, 1.0)
    }

    func testAccessibilityCallsTimeOutQuickly() {
        XCTAssertGreaterThan(AXHelper.messagingTimeout, 0)
        XCTAssertLessThanOrEqual(AXHelper.messagingTimeout, 0.2)
    }

    func testApplicationElementIsForThatProcess() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXHelper.application(pid)
        var elementPid: pid_t = 0
        XCTAssertEqual(AXUIElementGetPid(element, &elementPid), .success)
        XCTAssertEqual(elementPid, pid)
    }
}
