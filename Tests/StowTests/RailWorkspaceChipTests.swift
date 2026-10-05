import AppKit
import XCTest
@testable import StowCore
import StowShared

/// In the rail one workspace chip, the Tabline's element, stands for the workspaces: it
/// shows the current one, a click opens the same workspace list the Tabline's chip opens,
/// and a right-click opens the workspace editor.
@MainActor
final class RailWorkspaceChipTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.controller?.workspaceEditor.close()
        harness.controller?.railView.flyout.closeAll()
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }
    private var main: MainViewController { harness.controller }
    private var editor: WorkspaceEditorController { harness.controller.workspaceEditor }

    private func rail() throws -> RailView {
        try XCTUnwrap(main.view.descendants(of: RailView.self).first)
    }

    private func rightClick(_ view: NSView) {
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: 0,
                                       windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        view.rightMouseDown(with: event)
    }

    private func footer(_ list: FlyoutListView) -> [FlyoutButton] {
        list.descendants(of: FlyoutButton.self)
    }

    // MARK: The chip

    func testTheChipShowsTheCurrentWorkspacesIdentity() throws {
        let second = model.createWorkspace(name: "Reading", colorId: .ocean)
        model.updateWorkspaceIcon(id: second, icon: .symbol("book"))
        harness.host(width: 52)
        main.selectWorkspaceAndPage(second)
        harness.spin()
        let chip = try rail().workspaceChip
        XCTAssertEqual(chip.content?.id, second)
        XCTAssertEqual(chip.content?.colorId, .ocean)
        XCTAssertEqual(chip.content?.identity, WorkspaceTileIdentity.resolve(model.workspaces)[second])
        XCTAssertEqual(chip.content?.identity, .symbol("book"))
        XCTAssertEqual(chip.accessibilityLabel(), "Workspace: Reading")
        XCTAssertNotNil(chip.accessibilityHelp())
    }

    func testTheChipSitsUnderTheGear() throws {
        harness.host(width: 52)
        let rail = try rail()
        rail.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(rail.workspaceChip.frame.minY, rail.settingsGear.frame.maxY - 0.5)
        XCTAssertEqual(rail.workspaceChip.frame.midX, rail.bounds.midX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(rail.workspaceChip.frame.width, 52)
    }

    func testTheRailHasNoWorkspaceDots() throws {
        _ = model.createWorkspace(name: "Reading", colorId: .ocean)
        harness.host(width: 52)
        let rail = try rail()
        let names = Set(model.workspaces.map(\.name))
        let dots = rail.descendants(of: NSButton.self).filter { names.contains($0.accessibilityLabel() ?? "") }
        XCTAssertTrue(dots.isEmpty, "the chip replaces the dot stack")
        let glyphs = rail.descendants(of: RailGlyphButton.self).compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(glyphs.contains("New workspace…"), "New workspace… lives in the list's footer")
    }

    // MARK: Click: the shared workspace list

    func testClickingTheChipOpensTheSameListAsTheTablineChip() throws {
        let second = model.createWorkspace(name: "Reading", colorId: .ocean)
        harness.host(width: 52)
        main.selectWorkspaceAndPage(model.workspaces[0].id)
        harness.spin()
        harness.window.orderFront(nil)
        let rail = try rail()
        rail.workspaceChip.performAction()
        let list = try XCTUnwrap(rail.flyout.rootList, "the chip opens a list flyout")
        XCTAssertEqual(list.rows.map(\.title), model.workspaces.map(\.name))
        XCTAssertEqual(list.rows.filter(\.isChecked).map(\.id), [model.workspaces[0].id.uuidString], "✓ on the current one")
        XCTAssertEqual(list.rows.map(\.trailing), ["⌘1", "⌘2"])
        XCTAssertEqual(footer(list).map(\.title), ["Edit Workspace…", "New workspace…"])

        let tabline = try XCTUnwrap(TablineController.shared.chipList(), "the Tabline builds the same list")
        XCTAssertTrue(type(of: tabline) == type(of: list))
        XCTAssertEqual(tabline.rows.map(\.id), list.rows.map(\.id))
        XCTAssertEqual(tabline.rows.map(\.title), list.rows.map(\.title))
        XCTAssertEqual(footer(tabline).map(\.title), footer(list).map(\.title))
        _ = second
    }

    func testPickingARowSwitchesWorkspace() throws {
        let second = model.createWorkspace(name: "Reading", colorId: .ocean)
        harness.host(width: 52)
        main.selectWorkspaceAndPage(model.workspaces[0].id)
        harness.spin()
        harness.window.orderFront(nil)
        let rail = try rail()
        rail.workspaceChip.performAction()
        let list = try XCTUnwrap(rail.flyout.rootList)
        let row = try XCTUnwrap(list.rowViews.first { $0.row.id == second.uuidString })
        list.onActivate?(row.row, row)
        XCTAssertEqual(model.currentWorkspace.id, second)
    }

    func testTheFooterEditsTheCurrentWorkspaceAndCreatesNewOnes() throws {
        harness.host(width: 52)
        harness.window.orderFront(nil)
        let rail = try rail()
        rail.workspaceChip.performAction()
        var list = try XCTUnwrap(rail.flyout.rootList)
        try XCTUnwrap(footer(list).first { $0.title == "Edit Workspace…" }).performAction()
        XCTAssertEqual(editor.editingId, model.currentWorkspace.id)
        XCTAssertFalse(editor.isNew)
        editor.close()

        rail.workspaceChip.performAction()
        list = try XCTUnwrap(rail.flyout.rootList)
        let before = model.workspaces.count
        try XCTUnwrap(footer(list).first { $0.title == "New workspace…" }).performAction()
        XCTAssertTrue(editor.isNew, "New workspace… opens the editor with an empty name")
        XCTAssertEqual(model.workspaces.count, before)
        editor.cancel()
        XCTAssertEqual(model.workspaces.count, before, "Esc creates nothing")
    }

    func testTheTablineChipListOffersNewWorkspaceToo() {
        var ran: [String] = []
        let footer = WorkspaceListFlyout.footer(edit: { ran.append("edit") }, newWorkspace: { ran.append("new") })
        XCTAssertEqual(footer.map(\.title), ["Edit Workspace…", "New workspace…"])
        footer.forEach { $0.action() }
        XCTAssertEqual(ran, ["edit", "new"])
    }

    func testTheTablineListsNewWorkspaceOpensTheEditor() {
        harness.host(width: 320)
        TablineController.shared.onNewWorkspace?(main.view, .zero)
        XCTAssertTrue(editor.isNew)
    }

    func testRightClickingARowInTheRailListOpensTheEditor() throws {
        let second = model.createWorkspace(name: "Reading", colorId: .ocean)
        harness.host(width: 52)
        try rail().flyout.onWorkspaceMenu?(second, try rail().workspaceChip)
        XCTAssertEqual(editor.editingId, second)
    }

    // MARK: Right-click and the keyboard: the editor

    func testRightClickingTheChipOpensTheEditor() throws {
        harness.host(width: 52)
        rightClick(try rail().workspaceChip)
        XCTAssertEqual(editor.editingId, model.currentWorkspace.id)
        XCTAssertFalse(editor.isNew)
    }

    func testControlReturnAndShowMenuOnTheChipOpenTheEditor() throws {
        harness.host(width: 52)
        let chip = try rail().workspaceChip
        let controlReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                             isARepeat: false, keyCode: 36)!
        chip.keyDown(with: controlReturn)
        XCTAssertEqual(editor.editingId, model.currentWorkspace.id, "⌃Return is the keyboard's right-click")
        editor.close()
        XCTAssertTrue(chip.accessibilityPerformShowMenu())
        XCTAssertEqual(editor.editingId, model.currentWorkspace.id)
    }

    func testCommandNInTheRailOpensTheEditorAtTheChip() throws {
        harness.host(width: 52)
        main.promptCreateWorkspace()
        XCTAssertTrue(editor.isNew)
    }

    // MARK: Swiping

    func testTheChipFollowsASwipe() throws {
        let second = model.createWorkspace(name: "Reading", colorId: .ocean)
        harness.host(width: 52)
        main.selectWorkspaceAndPage(model.workspaces[0].id)
        harness.spin()
        main.pageSwipe.pagerDidUpdateOffset(1.4)
        XCTAssertEqual(try rail().workspaceChip.content?.id, second, "mid-swipe the chip shows the incoming workspace")
        main.pageSwipe.pagerDidSnapToPage(1)
        harness.spin()
        XCTAssertEqual(try rail().workspaceChip.content?.id, model.workspaces[0].id, "a swipe that snaps back puts it back")
    }
}

@MainActor
final class WorkspaceListFooterTests: XCTestCase {
    func testTheFootersButtonsFitTheList() {
        let list = WorkspaceListFlyout.make(workspaces: [(UUID(), "Research", .ocean)], current: nil, edit: {}, newWorkspace: {})
        list.frame.size = list.preferredSize
        list.layoutSubtreeIfNeeded()
        let buttons = list.descendants(of: FlyoutButton.self)
        XCTAssertEqual(buttons.map(\.title), ["Edit Workspace…", "New workspace…"])
        for button in buttons {
            XCTAssertLessThanOrEqual(button.frame.maxX, list.bounds.width - FlyoutListView.Metrics.padding + 0.5, "\(button.title) is cut")
            XCTAssertLessThanOrEqual(button.frame.maxY, list.bounds.height + 0.5)
        }
        XCTAssertFalse(buttons[0].frame.intersects(buttons[1].frame))
    }
}
