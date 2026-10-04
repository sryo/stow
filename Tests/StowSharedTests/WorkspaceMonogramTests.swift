import XCTest
@testable import StowShared

final class WorkspaceMonogramTests: XCTestCase {
    func testALoneNameIsItsFirstLetter() {
        XCTAssertEqual(WorkspaceMonogram.resolve(UUID(), name: "work stuff"), "W")
        XCTAssertEqual(WorkspaceMonogram.resolve(UUID(), name: "  "), "?")
    }

    func testCollidingFirstLettersTakeASecondLetter() {
        let work = UUID(), writing = UUID(), home = UUID()
        let letters = WorkspaceMonogram.assign([(work, "Work"), (writing, "Writing"), (home, "Home")])
        XCTAssertEqual(letters[work], "Wo")
        XCTAssertEqual(letters[writing], "Wr")
        XCTAssertEqual(letters[home], "H")
    }

    func testTwoWordNamesUseInitialsOnACollision() {
        let a = UUID(), b = UUID()
        let letters = WorkspaceMonogram.assign([(a, "Side Project"), (b, "Shopping")])
        XCTAssertEqual(letters[a], "SP")
        XCTAssertEqual(letters[b], "Sh")
    }

    func testResolveMatchesAssignAcrossTheList() {
        let work = UUID(), writing = UUID()
        let all = [(id: work, name: "Work"), (id: writing, name: "Writing")]
        XCTAssertEqual(WorkspaceMonogram.resolve(work, name: "Work", among: all), "Wo")
    }
}
