import AppKit
import XCTest
@testable import StowCore
import StowShared

/// The link whose page is the browser's active tab gets the selected-row fill, in the
/// list, the mosaic and the rail, and says so to VoiceOver.
@MainActor
final class ActiveTabTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws { harness = RedHarness() }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    private func labels() -> [String] {
        harness.controller.view.descendants(of: NSView.self).compactMap { $0.accessibilityLabel() }
    }

    private func showActive(width: CGFloat) {
        _ = harness.model.addLink(urlString: "https://www.figma.com/design/HP8r/Untitled?node-id=1", title: "Design", parentId: nil)
        _ = harness.model.addLink(urlString: "https://example.com/other", title: "Other", parentId: nil)
        harness.host(width: width)
        harness.controller.setActivePage(URL(string: "https://www.figma.com/design/HP8r/Untitled?node-id=99")!)
        harness.spin(0.2)
    }

    func testTheListMarksTheActiveTabsLink() {
        showActive(width: 400)
        XCTAssertTrue(labels().contains { $0.contains("Design") && $0.hasSuffix(", front tab") }, labels().joined(separator: "\n"))
        XCTAssertFalse(labels().contains { $0.contains("Other") && $0.hasSuffix(", front tab") })
    }

    func testTheMosaicMarksTheActiveTabsLink() {
        showActive(width: 900)
        XCTAssertTrue(labels().contains { $0.contains("Design") && $0.hasSuffix(", front tab") }, labels().joined(separator: "\n"))
    }

    func testTheRailMarksTheActiveTabsLink() {
        showActive(width: ElasticMode.railWidth)
        let cells = harness.controller.view.descendants(of: RailCell.self)
        XCTAssertEqual(cells.filter(\.isActive).compactMap { $0.node?.displayName }, ["Design"])
    }

    func testNoActivePageMarksNothing() {
        showActive(width: 400)
        harness.controller.setActivePage(nil)
        harness.spin(0.2)
        XCTAssertFalse(labels().contains { $0.hasSuffix(", front tab") }, labels().filter { $0.hasSuffix(", front tab") }.joined(separator: " | "))
    }
}
