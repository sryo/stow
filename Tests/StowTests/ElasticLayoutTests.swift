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
}
