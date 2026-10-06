import AppKit
import XCTest
@testable import StowCore
import StowShared

/// The page sliding in mid-swipe shows its own empty state: an empty workspace's
/// welcome doesn't ride along over a full one, and a full one's rows don't hide an
/// empty neighbour's welcome.
@MainActor
final class SwipeEmptyStateTests: XCTestCase {
    private var tempDir: URL!
    private var window: NSWindow!
    private var controller: MainViewController!
    private var model: AppModel!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        _ = model.createWorkspace(name: "Full")
        model.selectWorkspace(id: model.workspaces[1].id)
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        controller = MainViewController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 360, height: 620))
        window.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var overlay: EmptyStateView { controller.nodeListViewController.emptyStateOverlay }

    /// A dynamic colour as the light appearance draws it.
    private func rgb(_ color: NSColor?) -> [CGFloat]? {
        var out: [CGFloat]?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            out = [c.redComponent, c.greenComponent, c.blueComponent].map { ($0 * 1000).rounded() / 1000 }
        }
        return out
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
    }

    func testAnEmptyWorkspacesWelcomeDoesNotSlideOverTheFullOne() {
        model.selectWorkspace(id: model.workspaces[0].id)
        settle()
        XCTAssertFalse(overlay.isHidden, "precondition: the empty workspace shows its welcome")

        controller.pageSwipe.pagerDidUpdateOffset(1.4)   // from the empty page toward "Full"
        XCTAssertTrue(overlay.isHidden, "the empty state leaked onto the incoming full page")
    }

    func testAFullWorkspaceSwipingTowardAnEmptyOneShowsItsWelcome() {
        settle()
        XCTAssertTrue(overlay.isHidden, "precondition: the full workspace shows rows")

        controller.pageSwipe.pagerDidUpdateOffset(1.6)   // from "Full" back toward the empty page
        XCTAssertFalse(overlay.isHidden, "the incoming empty page lost its welcome")
    }

    func testTheIncomingWelcomeWearsItsOwnWorkspacesColour() {
        settle()
        let list = controller.nodeListViewController
        let empty = model.workspaces[0], full = model.workspaces[1]
        let emptySurface = StowTheme.colors(for: empty.colorId, tint: list.tintMode).surface
        let fullSurface = StowTheme.colors(for: full.colorId, tint: list.tintMode).surface
        XCTAssertNotEqual(rgb(emptySurface), rgb(fullSurface), "precondition: the two workspaces differ in colour")

        controller.pageSwipe.pagerDidUpdateOffset(1.6)   // from "Full" toward the empty page
        XCTAssertEqual(rgb(overlay.colors?.surface), rgb(emptySurface), "the previous page's colour leaked onto the welcome")
    }
}
