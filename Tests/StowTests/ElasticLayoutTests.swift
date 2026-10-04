import XCTest
import AppKit
@testable import StowCore

@MainActor
final class ElasticLayoutTests: XCTestCase {
    private func frames(mode: ElasticMode, width: CGFloat, shapes: [ElasticLayout.Shape]) -> [NSRect] {
        let layout = ElasticLayout()
        layout.mode = mode
        layout.shapes = shapes
        let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        collection.collectionViewLayout = layout
        layout.prepare()
        return shapes.indices.compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
    }

    func testMosaicColumnsFollowTheMockup() {
        // 118pt minimum tiles with 8pt gaps inside 8pt side insets, never fewer than two.
        XCTAssertEqual(ElasticLayout.columns(forWidth: 200), 2)
        XCTAssertEqual(ElasticLayout.columns(forWidth: 520 - 12), 3)
        XCTAssertEqual(ElasticLayout.columns(forWidth: 820 - 12), 6)
    }

    func testTasksSpanTwoColumnsFromFourColumns() {
        let wide = frames(mode: .mosaic, width: 808, shapes: [.sectionHeader, .taskTile, .taskTile])
        let tile = (808 - 16 - 5 * 8) / 6.0
        XCTAssertEqual(wide[1].width, tile * 2 + 8, accuracy: 0.5)
        XCTAssertEqual(wide[2].minY, wide[1].minY, "two wide tasks share a row")

        let narrow = frames(mode: .mosaic, width: 420, shapes: [.taskTile, .snippetTile])
        XCTAssertEqual(narrow[0].width, 420 - 16, accuracy: 0.5, "fewer than four columns: full width")
        XCTAssertGreaterThan(narrow[1].minY, narrow[0].maxY)
    }

    func testGroupHeadersStartNewRows() {
        let f = frames(mode: .mosaic, width: 808, shapes: [.sectionHeader, .linkTile, .groupHeader, .linkTile])
        XCTAssertEqual(f[0].height, 24)
        XCTAssertEqual(f[1].height, 80)
        XCTAssertEqual(f[2].minY, f[1].maxY + 8 + 10, "group gap after a row of tiles")
        XCTAssertEqual(f[3].minY, f[2].maxY + 4)
    }

    func testSidebarSectionsHaveGapsAndShortHeaders() {
        let f = frames(mode: .sidebar, width: 288, shapes: [.row, .sectionHeader, .row, .sectionHeader, .row])
        XCTAssertEqual(f[0].minY, 4)
        XCTAssertEqual(f[1].minY, f[0].maxY + 10)
        XCTAssertEqual(f[1].height, 26)
        XCTAssertEqual(f[3].minY, f[2].maxY + 6)
    }

    // MARK: - Keyboard neighbours

    /// Two lines of three tiles under a header, then a wide tile on its own line:
    /// 0 header, 1 2 3 / 4 5 6 / 7 (wide, spans the first two columns).
    private let grid: [NSRect] = [
        NSRect(x: 0, y: 0, width: 300, height: 24),
        NSRect(x: 0, y: 30, width: 90, height: 80), NSRect(x: 100, y: 30, width: 90, height: 80), NSRect(x: 200, y: 30, width: 90, height: 80),
        NSRect(x: 0, y: 120, width: 90, height: 80), NSRect(x: 100, y: 120, width: 90, height: 80), NSRect(x: 200, y: 120, width: 90, height: 80),
        NSRect(x: 0, y: 210, width: 190, height: 38),
    ]

    func testDownAndUpMoveToTheNearestTileOnTheNextLine() {
        XCTAssertEqual(ElasticLayout.neighbor(of: 2, direction: .down, in: grid), 5)
        XCTAssertEqual(ElasticLayout.neighbor(of: 6, direction: .up, in: grid), 3)
        XCTAssertEqual(ElasticLayout.neighbor(of: 6, direction: .down, in: grid), 7, "nearest by midX on a shorter line")
        XCTAssertEqual(ElasticLayout.neighbor(of: 7, direction: .up, in: grid), 4, "a wide tile midway between two columns goes to the earlier one")
        XCTAssertNil(ElasticLayout.neighbor(of: 7, direction: .down, in: grid), "nothing below the last line")
    }

    func testLeftAndRightStayOnTheLine() {
        XCTAssertEqual(ElasticLayout.neighbor(of: 2, direction: .right, in: grid), 3)
        XCTAssertEqual(ElasticLayout.neighbor(of: 2, direction: .left, in: grid), 1)
        XCTAssertNil(ElasticLayout.neighbor(of: 3, direction: .right, in: grid), "no wrapping onto the next line")
        XCTAssertNil(ElasticLayout.neighbor(of: 4, direction: .left, in: grid))
        XCTAssertNil(ElasticLayout.neighbor(of: 0, direction: .right, in: grid), "a header has no horizontal neighbour")
    }

    func testIneligibleItemsAreSkipped() {
        let tiles: (Int) -> Bool = { $0 != 0 }
        XCTAssertNil(ElasticLayout.neighbor(of: 2, direction: .up, in: grid, eligible: tiles), "the header line is not a stop")
        XCTAssertEqual(ElasticLayout.neighbor(of: 2, direction: .up, in: grid), 0)
        XCTAssertEqual(ElasticLayout.neighbor(of: 4, direction: .down, in: grid, eligible: { $0 != 7 }), nil)
    }

    func testTilesOfDifferentHeightsShareALine() {
        let mixed = [NSRect(x: 0, y: 0, width: 90, height: 80), NSRect(x: 100, y: 0, width: 190, height: 38),
                     NSRect(x: 0, y: 90, width: 90, height: 80)]
        XCTAssertEqual(ElasticLayout.neighbor(of: 0, direction: .right, in: mixed), 1)
        XCTAssertEqual(ElasticLayout.neighbor(of: 1, direction: .down, in: mixed), 2)
    }
}
