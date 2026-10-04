import AppKit
import XCTest
@testable import StowCore
import StowShared

/// A swipe that changes direction or ends on a different page must leave exactly one
/// page on screen: no leftover snapshot, Settings hidden on a workspace page, and the
/// list back in place.
@MainActor
final class SwipeCleanupTests: XCTestCase {
    private var tempDir: URL!
    private var window: NSWindow!
    private var controller: MainViewController!
    private var model: AppModel!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        _ = model.createWorkspace(name: "Second")
        model.selectWorkspace(id: model.workspaces[0].id)
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        controller = MainViewController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 360, height: 620))
        window.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var settingsView: NSView { controller.children.first { $0 is SettingsContentViewController }!.view }
    private var listView: NSView { controller.children.first { $0 is NodeListViewController }!.view }
    private var strayImageViews: [NSImageView] { controller.view.subviews.compactMap { $0 as? NSImageView } }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
    }

    private func assertOnlyWorkspacePageShowing(file: StaticString = #filePath, line: UInt = #line) {
        settle()
        XCTAssertTrue(settingsView.isHidden, "Settings still showing over a workspace page", file: file, line: line)
        XCTAssertTrue(strayImageViews.isEmpty, "leftover swipe snapshot", file: file, line: line)
        XCTAssertEqual(listView.layer?.transform.m41 ?? 0, 0, "list still shifted", file: file, line: line)
        XCTAssertEqual(listView.alphaValue, 1, file: file, line: line)
    }

    func testSwipeTowardSettingsThenBackSnapsCleanly() {
        controller.pageSwipe.pagerDidUpdateOffset(0.7)   // from workspace 1 toward Settings
        controller.pageSwipe.pagerDidUpdateOffset(1.3)   // changes its mind, toward workspace 2
        controller.pageSwipe.pagerDidSnapToPage(1)       // lets go: springs back to workspace 1
        assertOnlyWorkspacePageShowing()
    }

    func testSwipeTowardSettingsThenOnToNextWorkspaceSnapsCleanly() {
        controller.pageSwipe.pagerDidUpdateOffset(0.6)
        controller.pageSwipe.pagerDidUpdateOffset(1.6)
        controller.pageSwipe.pagerDidSnapToPage(2)
        XCTAssertEqual(model.currentWorkspace.name, "Second")
        assertOnlyWorkspacePageShowing()
    }

    func testOverswipeIntoAddNewPageLeavesNoSettingsOrSnapshot() {
        model.selectWorkspace(id: model.workspaces[1].id)
        settle()
        controller.pageSwipe.pagerDidUpdateOffset(1.6)   // from workspace 2 back toward workspace 1...
        controller.pageSwipe.pagerDidUpdateOffset(2.5)   // ...then past the last page
        controller.pageSwipe.pagerDidSnapToPage(3)       // the add-new page
        assertOnlyWorkspacePageShowing()
    }

    func testTwoSwipesInARowLeaveNoSnapshotBehind() {
        controller.pageSwipe.pagerDidUpdateOffset(1.3)
        controller.pageSwipe.pagerDidSnapToPage(1)
        controller.pageSwipe.pagerDidUpdateOffset(1.4)
        controller.pageSwipe.pagerDidSnapToPage(1)
        assertOnlyWorkspacePageShowing()
    }

    /// Mid-swipe toward Settings, only the sliding Settings page and the outgoing picture
    /// of the list may show; the live list underneath must be hidden.
    func testMidSwipeTowardSettingsHidesTheLiveList() {
        controller.pageSwipe.pagerDidUpdateOffset(0.6)
        window.layoutIfNeeded()
        let contentStack = controller.view.subviews.first { $0 is NSStackView && $0.subviews.contains(listView) }
        XCTAssertFalse(settingsView.isHidden, "Settings should be sliding in")
        XCTAssertEqual(contentStack?.isHidden, true, "the live list shows through under the swipe")
        controller.pageSwipe.pagerDidSnapToPage(1)
    }

    /// The search field follows the background's blend while swiping, instead of keeping
    /// the old workspace's tint until the swipe ends.
    func testSearchFieldBlendsWithTheBackgroundMidSwipe() throws {
        func searchBar(in view: NSView) -> SearchBarView? {
            if let s = view as? SearchBarView { return s }
            for sub in view.subviews { if let s = searchBar(in: sub) { return s } }
            return nil
        }
        let search = try XCTUnwrap(searchBar(in: controller.view))
        controller.pageSwipe.pagerDidUpdateOffset(1.5)   // halfway from workspace 1 to workspace 2
        let from = StowTheme.colors(for: model.workspaces[0].colorId, tint: StowTheme.displayTint)
        let to = StowTheme.colors(for: model.workspaces[1].colorId, tint: StowTheme.displayTint)
        XCTAssertEqual(search.colors?.light.hover, from.blended(with: to, fraction: 0.5).light.hover)
        controller.pageSwipe.pagerDidSnapToPage(2)
        XCTAssertEqual(search.colors?.light.hover, to.light.hover)
    }
}
