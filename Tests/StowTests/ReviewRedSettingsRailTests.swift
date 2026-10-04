import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Red tests from the 2026-10 review that outlived the Settings rail: the flyouts'
/// outside clicks and the workspace editor (review/red-tests.md).
@MainActor
final class ReviewRedSettingsRailTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    // MARK: patterns-3

    func testAClickInsideTheAllShortcutsPopoverKeepsTheAppSheetOpen() {
        let closes = FlyoutDismissPolicy.clickCloses(inStack: false, inHost: false, isColorPanel: false,
                                                     windowClassName: "_NSPopoverWindow")
        XCTAssertFalse(closes,
                       "patterns-3: the outside-click monitor only spares windows named *Menu*, so a click in the popover closes its parent sheet")
    }

    // MARK: patterns-10

    func testEditorLetterPreviewMatchesTheLetterTile() {
        let work = model.currentWorkspace.id
        model.renameWorkspace(id: work, newName: "Work")
        let writing = model.createWorkspace(name: "Writing", colorId: .moss)
        model.updateWorkspaceIcon(id: work, icon: .letter)
        model.updateWorkspaceIcon(id: writing, icon: .letter)
        let identities = WorkspaceTileIdentity.resolve(model.workspaces)
        let controller = WorkspaceEditorController(model: model)
        let ws = model.workspaces.first { $0.id == work }!
        let content = controller.editorContent(for: ws, identities: identities)
        XCTAssertEqual(content.letter, identities[work],
                       "patterns-10: the editor runs assignMonograms on this workspace alone, so \"Work\" next to \"Writing\" previews a different letter than its tile")
    }

    // MARK: code-health-9

    func testColorPanelStopsRecoloringOnceTheEditorCloses() {
        let id = model.currentWorkspace.id
        model.updateWorkspaceColor(id: id, colorId: .ocean)
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 400), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.orderOut(nil) }
        let controller = WorkspaceEditorController(model: model)
        controller.open(id, placement: { .init(anchor: host.frame, edge: .below, parent: host) })
        XCTAssertEqual(controller.editingId, id, "precondition: the editor opened")
        controller.chooseCustomColor()
        controller.close()
        XCTAssertNil(controller.editingId, "precondition: the editor closed")
        NSColorPanel.shared.color = .systemRed
        controller.customColorChanged(NSColorPanel.shared)
        XCTAssertEqual(model.workspaces.first { $0.id == id }?.colorId, .ocean,
                       "code-health-9: colorPanelWorkspace is never cleared, so the still-open color panel keeps recoloring a closed editor's workspace")
    }
}
