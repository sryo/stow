import XCTest
@testable import StowCore

/// A drop the list won't take says why, once per reason per drag.
@MainActor
final class DropRefusalTests: XCTestCase {

    func testSearchingSaysToClearTheSearch() {
        XCTAssertEqual(DropRefusal.reason(searchActive: true, dragged: .links, staysInSection: true),
                       "Clear the search to rearrange")
    }

    func testEachSectionSaysWhereItsItemsStay() {
        XCTAssertEqual(DropRefusal.reason(searchActive: false, dragged: .tasks, staysInSection: false), "Tasks stay with tasks")
        XCTAssertEqual(DropRefusal.reason(searchActive: false, dragged: .snippets, staysInSection: false), "Snippets stay with snippets")
        XCTAssertEqual(DropRefusal.reason(searchActive: false, dragged: .links, staysInSection: false),
                       "Links and folders stay above tasks and snippets")
    }

    func testAnAcceptedDropHasNoReason() {
        XCTAssertNil(DropRefusal.reason(searchActive: false, dragged: .links, staysInSection: true))
    }

    func testAReasonShowsOncePerDrag() {
        var shown: [String] = []
        var refusal = DropRefusal { shown.append($0) }
        refusal.note("A")
        refusal.note("A")
        refusal.note(nil)
        refusal.note("A")
        refusal.note("B")
        refusal.dragEnded()
        refusal.note("A")
        XCTAssertEqual(shown, ["A", "B", "A"])
    }
}
