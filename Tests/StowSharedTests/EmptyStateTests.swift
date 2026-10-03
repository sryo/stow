import XCTest
@testable import StowShared

final class EmptyStateTests: XCTestCase {

    private func kind(active: Int = 0, archived: Int = 0, query: String = "", matched: Int = 0,
                      archivedMatched: Int = 0, archiveExpanded: Bool = false,
                      firstLaunch: Bool = false, arc: Bool = false) -> EmptyStateKind {
        EmptyStateKind.resolve(activeCount: active, archivedCount: archived, query: query,
                               matchedCount: matched, archivedMatchedCount: archivedMatched,
                               isArchiveExpanded: archiveExpanded, isFirstLaunch: firstLaunch, hasArcData: arc)
    }

    func testResolver() {
        XCTAssertEqual(kind(active: 3), .none)
        XCTAssertEqual(kind(), .emptyWorkspace)
        XCTAssertEqual(kind(firstLaunch: true), .firstLaunch(hasArcData: false))
        XCTAssertEqual(kind(firstLaunch: true, arc: true), .firstLaunch(hasArcData: true))
        XCTAssertEqual(kind(archived: 3), .allArchived(count: 3))
        XCTAssertEqual(kind(archived: 3, archiveExpanded: true), .none)
        XCTAssertEqual(kind(active: 5, query: "x", matched: 2), .none)
        XCTAssertEqual(kind(active: 5, query: "x"), .noMatches(query: "x", total: 5))
        XCTAssertEqual(kind(active: 5, archived: 2, query: "x", archivedMatched: 2), .archivedMatches(query: "x", count: 2))
        // An archived workspace with a search still reports search results, not "all archived".
        XCTAssertEqual(kind(archived: 4, query: "x"), .noMatches(query: "x", total: 0))
    }

    private var allCopies: [EmptyStateCopy] {
        let kinds: [EmptyStateKind] = [
            .emptyWorkspace, .firstLaunch(hasArcData: false), .firstLaunch(hasArcData: true),
            .noMatches(query: "kubernetes", total: 37), .noMatches(query: "x", total: 1),
            .archivedMatches(query: "invoice", count: 1), .archivedMatches(query: "invoice", count: 3),
            .allArchived(count: 1), .allArchived(count: 3),
        ]
        return kinds.flatMap { k in [true, false].compactMap { EmptyStateCopy.make(k, workspaceName: "Research", isTouch: $0) } }
    }

    func testCopyRules() {
        let banned = ["you haven't", "nothing found", "error", "oops", "!"]
        for copy in allCopies {
            XCTAssertLessThanOrEqual(copy.message.count, 70, copy.message)
            XCTAssertEqual(copy.message.filter { $0 == "." }.count, 1, "one sentence: \(copy.message)")
            for word in banned {
                XCTAssertFalse(copy.title.lowercased().contains(word) || copy.message.lowercased().contains(word), copy.title)
            }
        }
        for copy in allCopies where copy.isTouch {
            XCTAssertFalse(copy.message.lowercased().contains("drag"), copy.message)
            XCTAssertFalse(copy.message.contains("⌘"), copy.message)
        }
        for copy in allCopies where !copy.isTouch {
            XCTAssertFalse(copy.message.lowercased().contains("tap"), copy.message)
        }
    }

    func testPlurals() {
        let one = EmptyStateCopy.make(.allArchived(count: 1), workspaceName: "W", isTouch: false)!
        let many = EmptyStateCopy.make(.allArchived(count: 3), workspaceName: "W", isTouch: false)!
        XCTAssertTrue(one.message.contains("1 item is"), one.message)
        XCTAssertTrue(many.message.contains("3 items are"), many.message)
        XCTAssertEqual(one.action, .showArchive(count: 1))
    }

    func testLongQueryIsMiddleTruncated() {
        let q = String(repeating: "abcdefghij", count: 5)
        let copy = EmptyStateCopy.make(.noMatches(query: q, total: 3), workspaceName: "W", isTouch: false)!
        XCTAssertTrue(copy.title.contains("…"))
        XCTAssertLessThan(copy.title.count, 50)
    }

    func testIllustrationColorsContrast() {
        let bases = WorkspaceColorId.allCases.map { StowTheme.RGB($0.color) }
            + [StowTheme.RGB(0.1, 0.1, 0.4), StowTheme.RGB(0.5, 0.5, 0.5), StowTheme.RGB(1, 1, 1)]
        for base in bases {
            for app in [StowTheme.Appearance.light, .dark] {
                for tint in StowTheme.TintMode.allCases {
                    let p = StowTheme.palette(base: base, appearance: app, tint: tint)
                    XCTAssertGreaterThanOrEqual(p.inkSecondary.contrast(with: p.paper), 3, "line on paper \(base.hex) \(app) \(tint)")
                    XCTAssertGreaterThanOrEqual(p.inkPrimary.contrast(with: p.paper), 4.5, "eyes on paper \(base.hex) \(app) \(tint)")
                    XCTAssertGreaterThanOrEqual(p.inkSecondary.contrast(with: p.hover), 3, "line on shade \(base.hex) \(app) \(tint)")
                }
            }
        }
    }
}
