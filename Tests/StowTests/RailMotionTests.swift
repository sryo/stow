import XCTest
@testable import StowCore

final class RailMotionTests: XCTestCase {
    func testTheMorphRunsOnlyWhenMotionIsWelcome() {
        XCTAssertTrue(RailMotion.animates(windowVisible: true, swiping: false, reduceMotion: false))
        XCTAssertFalse(RailMotion.animates(windowVisible: true, swiping: false, reduceMotion: true), "Reduce Motion swaps instantly")
        XCTAssertFalse(RailMotion.animates(windowVisible: false, swiping: false, reduceMotion: false))
        XCTAssertFalse(RailMotion.animates(windowVisible: true, swiping: true, reduceMotion: false))
    }
}
