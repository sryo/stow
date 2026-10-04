import AppKit
import XCTest
@testable import StowCore
import StowShared

/// The Tabline follows the model on its own, one open-tabs monitor feeds every surface,
/// swipes don't drop reloads, and the due-date popover closes itself.
@MainActor
final class StateAndSyncMacTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    // MARK: B14

    func testTheTablineFollowsAWorkspaceRenamedOnSettings() {
        harness.host(width: 400)
        let id = model.activeWorkspaceId
        model.selectSettings()
        model.renameWorkspace(id: id, newName: "Renamed")
        XCTAssertEqual(TablineController.shared.content.name, "Renamed")
        XCTAssertEqual(TablineController.shared.content.workspaces.first { $0.id == id }?.name, "Renamed")
    }

    func testTheTablineDropsADeletedWorkspaceFromItsMenu() {
        harness.host(width: 400)
        let doomed = model.createWorkspace(name: "Doomed", colorId: .ocean)
        model.selectSettings()
        model.deleteWorkspace(id: doomed)
        XCTAssertFalse(TablineController.shared.content.workspaces.contains { $0.id == doomed })
    }

    // MARK: B20

    func testASnapAfterAMidSwipeChangeShowsTheChange() {
        model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectWorkspace(id: model.workspaces[0].id)
        harness.host(width: 400)
        let controller = harness.controller!
        controller.pagerDidUpdateOffset(1.3)          // toward the second workspace
        let id = model.addLink(urlString: "https://late.test", title: "Late", parentId: nil)
        harness.spin()                                // the scheduled reload lands mid-swipe
        controller.pagerDidSnapToPage(1)              // springs back to the first workspace
        XCTAssertEqual(harness.nodeList.visibleNode(at: 0)?.id, id,
                       "the reload skipped mid-swipe runs once the swipe ends")
    }

    // MARK: C13

    func testTheTablineMarksOnlyTheExactOpenPageAsLive() {
        let docs = Link(id: UUID(), title: "Docs", url: "https://example.com/docs", faviconPath: nil)
        let blog = Link(id: UUID(), title: "Blog", url: "https://example.com/blog", faviconPath: nil)
        let live = TablineController.liveIndices(entries: [.link(docs), .link(blog)],
                                                 openKeys: [URLCanonical.key(URL(string: "https://EXAMPLE.com/docs#intro")!)])
        XCTAssertEqual(live, [0], "same host isn't enough; the page itself must be open")
    }

    func testTheMonitorPublishesCanonicalOpenURLs() {
        let monitor = OpenTabsMonitor(reader: .init(
            browsersRunning: { true },
            openURLs: { [URL(string: "HTTPS://Example.com/#x")!] },
            frontPage: { _ in nil }
        ), seed: nil)
        var received: Set<String> = []
        let subscription = monitor.$openKeys.sink { received = $0 }
        defer { subscription.cancel() }
        monitor.setDemand(.list, true)
        harness.spin(0.3)
        XCTAssertEqual(received, ["https://example.com"])
        monitor.setDemand(.list, false)
    }

    func testTheMonitorDoesNotRunScriptsWithNoBrowserOpen() {
        let reads = ReadCounter()
        let monitor = OpenTabsMonitor(reader: .init(
            browsersRunning: { false },
            openURLs: { reads.increment(); return [] },
            frontPage: { _ in nil }
        ), seed: nil)
        monitor.setDemand(.list, true)
        harness.spin(0.3)
        XCTAssertEqual(reads.value, 0)
        monitor.setDemand(.list, false)
    }

    func testTheMonitorStaysIdleWithoutDemand() {
        let reads = ReadCounter()
        let monitor = OpenTabsMonitor(reader: .init(
            browsersRunning: { true },
            openURLs: { reads.increment(); return [] },
            frontPage: { _ in nil }
        ), seed: nil)
        monitor.refreshNow()
        harness.spin(0.3)
        XCTAssertEqual(reads.value, 0)
    }

    // MARK: B5

    private func showDueDatePopover() throws -> (DueDatePopoverController, NSPopover, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 20))
        window.contentView?.addSubview(anchor)
        let editor = DueDatePopoverController(dueDate: nil) { _ in }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = editor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        harness.spin(0.1)
        try XCTSkipUnless(popover.isShown, "the popover couldn't be shown in this test session")
        return (editor, popover, window)
    }

    func testDueDatePopoverClosesOnCancel() throws {
        let (editor, popover, window) = try showDueDatePopover()
        defer { window.orderOut(nil) }
        editor.view.descendants(of: NSButton.self).first { $0.title == "Cancel" }?.performClick(nil)
        harness.spin(0.3)
        XCTAssertFalse(popover.isShown)
    }

    func testDueDatePopoverClosesOnEscape() throws {
        let (editor, popover, window) = try showDueDatePopover()
        defer { window.orderOut(nil) }
        editor.cancelOperation(nil)
        harness.spin(0.3)
        XCTAssertFalse(popover.isShown)
    }

    func testDueDatePopoverOpensTowardTheRoomierSideOfTheWindow() {
        // A row near the top of a 600pt window (unflipped: high y) opens below it.
        XCTAssertEqual(DueDatePopoverController.preferredEdge(rowInWindow: NSRect(x: 0, y: 560, width: 200, height: 24),
                                                              windowHeight: 600, anchorIsFlipped: false), .minY)
        XCTAssertEqual(DueDatePopoverController.preferredEdge(rowInWindow: NSRect(x: 0, y: 560, width: 200, height: 24),
                                                              windowHeight: 600, anchorIsFlipped: true), .maxY)
        // A row near the bottom opens above it.
        XCTAssertEqual(DueDatePopoverController.preferredEdge(rowInWindow: NSRect(x: 0, y: 20, width: 200, height: 24),
                                                              windowHeight: 600, anchorIsFlipped: false), .maxY)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
