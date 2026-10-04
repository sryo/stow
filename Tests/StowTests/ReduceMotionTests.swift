import AppKit
import XCTest
@testable import StowCore
import StowShared

/// With Reduce Motion on, list rows and workspace pages change without sliding,
/// fading or snapping. (A fade-in can't be observed in an off-screen test window,
/// so insertion is covered by the same branch the removal test exercises.)
@MainActor
final class ReduceMotionTests: XCTestCase {
    private final class PagerSpy: ScrollWheelPageDelegate {
        var offsets: [CGFloat] = []
        var snapped: [Int] = []
        func pagerDidUpdateOffset(_ offset: CGFloat) { offsets.append(offset) }
        func pagerDidSnapToPage(_ pageIndex: Int) { snapped.append(pageIndex) }
        func pagerPageCount() -> Int { 3 }
        func pagerCurrentPage() -> Int { 0 }
    }

    func testThePagerJumpsStraightToThePageWithReduceMotion() {
        let pager = ScrollWheelPageController()
        let spy = PagerSpy()
        pager.delegate = spy
        pager.reduceMotion = { true }
        pager.animateToPage(2, from: 0.4)
        XCTAssertEqual(spy.snapped, [2], "the snap ran as a timed animation")
        XCTAssertEqual(spy.offsets, [2])
        pager.detach()
    }

    func testThePagerStillAnimatesWithoutReduceMotion() {
        let pager = ScrollWheelPageController()
        let spy = PagerSpy()
        pager.delegate = spy
        pager.reduceMotion = { false }
        pager.animateToPage(2, from: 0.4)
        XCTAssertEqual(spy.snapped, [], "precondition: the snap is animated")
        RunLoop.main.run(until: Date().addingTimeInterval(ThemeConstants.Paging.snapDuration + 0.1))
        XCTAssertEqual(spy.snapped, [2])
        pager.detach()
    }

    private func hostedList(reduceMotion: Bool) -> (RedHarness, NodeListViewController, NSCollectionView, UUID)? {
        let harness = RedHarness()
        let first = harness.model.addFolder(name: "Reading", parentId: nil, isExpanded: true)
        _ = harness.model.addLink(urlString: "https://a.example", title: "A", parentId: first)
        _ = harness.model.addLink(urlString: "https://b.example", title: "B", parentId: nil)
        harness.host(width: 400)
        let list = harness.nodeList
        list.reduceMotion = { reduceMotion }
        guard let collection = list.view.descendants(of: NSCollectionView.self).first else { return nil }
        return (harness, list, collection, first)
    }

    func testRemovedRowsDoNotSlideWithReduceMotion() throws {
        let (harness, _, collection, first) = try XCTUnwrap(hostedList(reduceMotion: true))
        defer { harness.tearDown() }
        harness.model.setFolderExpanded(id: first, isExpanded: false)
        harness.spin(0.02)
        XCTAssertTrue(collection.subviews.filter { $0 is NSImageView }.isEmpty, "a removed row left a sliding snapshot")
    }

    func testRemovedRowsStillSlideWithoutReduceMotion() throws {
        let (harness, _, collection, first) = try XCTUnwrap(hostedList(reduceMotion: false))
        defer { harness.tearDown() }
        harness.model.setFolderExpanded(id: first, isExpanded: false)
        harness.spin(0.02)
        XCTAssertFalse(collection.subviews.filter { $0 is NSImageView }.isEmpty, "precondition: removal is animated")
    }
}
