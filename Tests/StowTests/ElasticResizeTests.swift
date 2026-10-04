import AppKit
import XCTest
@testable import StowCore
import StowShared

/// The window must be able to narrow all the way to the rail in every state, or a drag
/// below the list width stops short and never snaps to the rail.
@MainActor
final class ElasticResizeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func narrowestWidth(_ configure: (AppModel) -> Void) -> CGFloat {
        let model = AppModel(store: DataStore(baseDirectory: tempDir))
        configure(model)
        let controller = MainViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 620),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 300, height: 620))
        window.layoutIfNeeded()
        window.setContentSize(NSSize(width: ElasticMode.railWidth, height: 620))
        window.layoutIfNeeded()
        // Required constraints that can't fit push the content back out; let them settle.
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView?.fittingSize.width ?? .greatestFiniteMagnitude
    }

    func testEmptyWorkspaceNarrowsToRail() {
        let width = narrowestWidth { model in
            for item in model.currentWorkspace.items { model.deleteNodeFromAnyWorkspace(id: item.id) }
        }
        XCTAssertLessThanOrEqual(width, ElasticMode.railWidth)
    }

    func testWorkspaceWithItemsNarrowsToRail() {
        let width = narrowestWidth { model in
            _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        }
        XCTAssertLessThanOrEqual(width, ElasticMode.railWidth)
    }

    func testSettingsPageNarrowsToRail() {
        let width = narrowestWidth { model in model.selectSettings() }
        XCTAssertLessThanOrEqual(width, ElasticMode.railWidth)
    }
}
