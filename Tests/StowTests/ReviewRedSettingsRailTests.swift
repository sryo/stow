import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Red tests from the 2026-10 review for Settings in the rail: the flyouts, the
/// workspace editor and the tile tip (review/red-tests.md).
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
        let closes = SettingsRailController.clickClosesFlyouts(inFlyout: false, inRail: false, isColorPanel: false,
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
        let controller = SettingsRailController(model: model)
        let ws = model.workspaces.first { $0.id == work }!
        let content = controller.editorContent(for: ws, identities: identities)
        XCTAssertEqual(content.letter, identities[work],
                       "patterns-10: the editor runs assignMonograms on this workspace alone, so \"Work\" next to \"Writing\" previews a different letter than its tile")
    }

    // MARK: patterns-13

    func testTileTipNamesTheRealWorkspaceShortcut() {
        let controller = SettingsRailController(model: model)
        let detail = controller.detail(for: model.currentWorkspace, position: 1)
        XCTAssertTrue(detail.contains("⌘1"),
                      "patterns-13: the tile tip and VoiceOver label say \"\(detail)\", but AppMenus binds Workspace 1 to ⌘1")
    }

    // MARK: code-health-9

    func testColorPanelStopsRecoloringOnceTheEditorCloses() {
        let id = model.currentWorkspace.id
        model.updateWorkspaceColor(id: id, colorId: .ocean)
        let controller = SettingsRailController(model: model)
        controller.view.onTileClick?(id)
        XCTAssertEqual(controller.editingId, id, "precondition: the editor opened")
        controller.chooseCustomColor()
        controller.view.onTileClick?(id)
        XCTAssertNil(controller.editingId, "precondition: the editor closed")
        NSColorPanel.shared.color = .systemRed
        controller.customColorChanged(NSColorPanel.shared)
        XCTAssertEqual(model.workspaces.first { $0.id == id }?.colorId, .ocean,
                       "code-health-9: colorPanelWorkspace is never cleared, so the still-open color panel keeps recoloring a closed editor's workspace")
    }
}
