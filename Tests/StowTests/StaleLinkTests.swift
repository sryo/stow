import AppKit
import XCTest
@testable import StowCore
import StowShared

/// A link not opened on this Mac for a while fades in the list and says so to VoiceOver.
@MainActor
final class StaleLinkTests: XCTestCase {
    private var harness: RedHarness!
    private var file: URL!
    private var now = Date()

    override func setUp() async throws {
        harness = RedHarness()
        file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recency-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
        try? FileManager.default.removeItem(at: file)
    }

    private func label(of id: UUID) -> String? {
        harness.controller.view.descendants(of: NodeRowView.self)
            .first { $0.accessibilityLabel()?.contains(id == stale ? "Old" : "New") == true }?
            .accessibilityLabel()
    }

    private var stale: UUID!

    func testAStaleLinkSaysSoAndAFreshOneDoesNot() {
        stale = harness.model.addLink(urlString: "https://old.test", title: "Old", parentId: nil)
        let fresh = harness.model.addLink(urlString: "https://new.test", title: "New", parentId: nil)
        let recency = LinkRecency(file: file, now: { [unowned self] in self.now })
        _ = recency.isStale(stale)
        now += (LinkRecency.staleAfterDays + 1) * 86_400
        recency.noteOpened(fresh)
        harness.host(width: 400)
        harness.nodeList.recency = recency
        harness.nodeList.reloadData(with: harness.model.currentWorkspace.items, forceExpand: false)
        harness.spin(0.2)

        XCTAssertTrue(label(of: stale)?.contains("not opened lately") == true, label(of: stale) ?? "no row")
        XCTAssertFalse(label(of: fresh)?.contains("not opened lately") ?? true)
    }
}
