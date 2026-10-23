import XCTest
@testable import StowShared

/// Links not opened on this Mac for a while read as stale. Opens are kept per Mac and
/// never synced; a link first seen recently is never stale.
@MainActor
final class LinkRecencyTests: XCTestCase {
    private var file: URL!
    private var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recency-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func recency() -> LinkRecency { LinkRecency(file: file, now: { [unowned self] in self.now }) }

    private func advance(days: Double) { now += days * 86_400 }

    func testALinkSeenForTheFirstTimeIsNotStale() {
        XCTAssertFalse(recency().isStale(UUID()))
    }

    func testALinkUnopenedSinceItWasFirstSeenGoesStale() {
        let r = recency(), id = UUID()
        _ = r.isStale(id)
        advance(days: LinkRecency.staleAfterDays - 1)
        XCTAssertFalse(r.isStale(id))
        advance(days: 2)
        XCTAssertTrue(r.isStale(id))
    }

    func testOpeningALinkMakesItFreshAgain() {
        let r = recency(), id = UUID()
        _ = r.isStale(id)
        advance(days: LinkRecency.staleAfterDays + 1)
        r.noteOpened(id)
        XCTAssertFalse(r.isStale(id))
    }

    func testOpensSurviveARelaunch() {
        let id = UUID()
        recency().noteOpened(id)
        advance(days: LinkRecency.staleAfterDays + 1)
        let reopened = recency()
        XCTAssertTrue(reopened.isStale(id))
        XCTAssertEqual(reopened.lastOpened(id), now - (LinkRecency.staleAfterDays + 1) * 86_400)
    }
}
