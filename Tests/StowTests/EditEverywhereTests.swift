import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Right-click on any workspace opens the one workspace editor beside it; Settings is
/// app settings only, at every width; new workspaces are named in that editor before
/// they exist.
@MainActor
final class EditEverywhereTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.controller?.workspaceEditor.close()
        harness.controller?.appSheet.close()
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
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

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    // MARK: Right-click opens the editor, on every surface

    func testRightClickingAStripTabOpensTheEditorOnThatWorkspace() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        let tab = try XCTUnwrap(main.workspaceSwitcher.tabView(for: second))
        rightClick(tab)
        XCTAssertEqual(editor.editingId, second)
    }

    func testRightClickingAMoreWorkspacesRowOpensTheEditor() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        let presenter = main.workspaceSwitcher.overflowFlyout
        presenter.onWorkspaceMenu?(second, main.workspaceSwitcher)
        XCTAssertEqual(editor.editingId, second, "the overflow list's rows have the same right-click")
    }

    func testAWorkspaceRowInAFlyoutListAsksForTheEditorOnRightClick() throws {
        let ids = [UUID(), UUID()]
        let rows = FlyoutListModel.rows(forWorkspaces: [(ids[0], "One", .ocean, .letter("O")), (ids[1], "Two", .ember, .letter("T"))], current: ids[0],
                                        shortcut: { _ in nil })
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 300), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        defer { host.orderOut(nil) }
        let presenter = FlyoutListPresenter()
        var asked: UUID?
        presenter.onWorkspaceMenu = { id, _ in asked = id }
        let list = FlyoutListView(title: "More workspaces", detail: "2", rows: rows)
        presenter.show(list, id: "overflow", anchor: NSRect(x: 120, y: 300, width: 20, height: 20), edge: .below,
                       topInset: 0, parent: host, takeKeyboard: false)
        defer { presenter.closeAll() }
        let rowView = try XCTUnwrap(list.descendants(of: FlyoutListRowView.self).last)
        rightClick(rowView)
        XCTAssertEqual(asked, ids[1])
    }

    func testRightClickingTheTablineChipOpensTheEditor() throws {
        harness.host(width: 320)
        let tabline = TablineController.shared
        let id = model.currentWorkspace.id
        tabline.strip.onContextMenu?(.chip, NSRect(x: 40, y: 4, width: 80, height: 24))
        XCTAssertEqual(editor.editingId, id, "the chip's right-click opens the editor")
    }

    func testRightClickingARowInTheTablineChipListOpensTheEditor() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        TablineController.shared.flyout.onWorkspaceMenu?(second, NSView())
        XCTAssertEqual(editor.editingId, second)
    }

    // MARK: One editor

    func testEverySurfaceSharesOneEditor() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        let before = WorkspaceEditorController.liveCount
        harness.host(width: 52)
        rightClick(try rail().workspaceChip)
        main.toggleSettings()
        harness.window.setContentSize(NSSize(width: 320, height: 620))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        harness.spin()
        rightClick(try XCTUnwrap(main.workspaceSwitcher.tabView(for: second)))
        TablineController.shared.strip.onContextMenu?(.chip, .zero)
        XCTAssertEqual(WorkspaceEditorController.liveCount - before, 1, "one editor instance for the whole window")
    }

    func testThereIsNoWorkspaceMenuAnyMore() {
        XCTAssertNil(NSClassFromString("StowCore.WorkspaceMenu"), "the editor replaced the right-click menu")
        XCTAssertNil(NSClassFromString("StowCore.SettingsRailController"))
        XCTAssertNil(NSClassFromString("StowCore.SettingsRailView"))
    }

    // MARK: The editor has what the menu had

    func testTheEditorOffersExportBesideShare() throws {
        let view = WorkspaceEditorView()
        let titles = view.descendants(of: FlyoutButton.self).map(\.title)
        let share = try XCTUnwrap(titles.firstIndex(of: "Share…"))
        let export = try XCTUnwrap(titles.firstIndex(of: "Export…"))
        XCTAssertEqual(export, share + 1, "Export… sits next to Share…")
    }

    func testTheEditorsFooterButtonsDontOverlap() throws {
        let controller = WorkspaceEditorController(model: model)
        let view = controller.editor
        let ws = model.currentWorkspace
        view.configure(controller.editorContent(for: ws, identities: WorkspaceTileIdentity.resolve(model.workspaces)))
        view.frame.size = NSSize(width: WorkspaceEditorView.width, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        let buttons = view.descendants(of: FlyoutButton.self).sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(buttons.count, 4)
        for (a, b) in zip(buttons, buttons.dropFirst()) {
            XCTAssertLessThanOrEqual(a.frame.maxX, b.frame.minX, "\(a.title) runs into \(b.title)")
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(buttons.last).frame.maxX, WorkspaceEditorView.width - 12 + 0.5)
        XCTAssertEqual(buttons.last?.accessibilityLabel(), "Delete", "the trash still says Delete to VoiceOver")
    }

    func testTheEditorsExportExportsThatWorkspace() throws {
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 500), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.orderOut(nil) }
        let controller = WorkspaceEditorController(model: model)
        var exported: UUID?
        controller.export = { id, _ in exported = id }
        let id = model.currentWorkspace.id
        controller.open(id, placement: { .init(anchor: host.frame, edge: .below, parent: host) })
        controller.editor.onExport?()
        XCTAssertEqual(exported, id)
        controller.close()
    }

    func testWorkspaceExportWritesAFileThatImportsBack() throws {
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        let url = harness.tempDir.appendingPathComponent("out.stow")
        try WorkspaceExport.write(model.currentWorkspace.id, model: model, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("example.com"))
    }

    func testACustomColorPreviewsAndThenCommitsOnce() throws {
        harness.host(width: 320)
        let id = model.currentWorkspace.id
        let original = model.currentWorkspace.colorId
        main.editWorkspace(id, from: main.workspaceSwitcher, edge: .below)
        var writes = 0
        let subscription = model.changeOrigins.sink { _ in writes += 1 }
        defer { subscription.cancel() }
        editor.chooseCustomColor()
        for hex in [NSColor.systemRed, .systemGreen, .systemBlue] {
            NSColorPanel.shared.color = hex
            editor.customColorChanged(nil)
        }
        XCTAssertEqual(model.currentWorkspace.colorId, original, "dragging only previews")
        XCTAssertEqual(writes, 0)
        if case .custom = editor.shownColor(of: model.currentWorkspace) {} else { XCTFail("the editor shows the preview") }
        editor.close()
        XCTAssertEqual(writes, 1, "the colour is written once, when the editor closes")
        if case .custom = model.currentWorkspace.colorId {} else { XCTFail("the custom colour was committed") }
    }

    // MARK: Settings in the rail is the gear's sheet

    func testTheRailGearOpensTheAppSheetAndStaysOnTheWorkspace() throws {
        harness.host(width: 52)
        let workspace = model.currentWorkspace.id
        try rail().onSettings?()
        XCTAssertTrue(main.appSheet.isOpen, "the gear opens the app sheet beside the rail")
        XCTAssertFalse(model.state.isSettingsSelected, "there's no Settings page in the rail")
        XCTAssertEqual(model.currentWorkspace.id, workspace)
        try rail().onSettings?()
        XCTAssertFalse(main.appSheet.isOpen, "the gear closes it again")
    }

    func testCommandCommaTogglesTheSheetInTheRail() {
        harness.host(width: 52)
        main.toggleSettings()
        XCTAssertTrue(main.appSheet.isOpen)
        XCTAssertFalse(model.state.isSettingsSelected)
        main.toggleSettings()
        XCTAssertFalse(main.appSheet.isOpen)
    }

    func testEscClosesTheRailSheet() {
        harness.host(width: 52)
        main.toggleSettings()
        XCTAssertTrue(main.handleEscape(), "Esc is handled")
        XCTAssertFalse(main.appSheet.isOpen)
    }

    func testTheRailHasNoSettingsPage() throws {
        harness.host(width: 52)
        main.enterSettings()
        harness.spin()
        XCTAssertFalse(model.state.isSettingsSelected, "entering Settings in the rail opens the sheet instead")
        XCTAssertTrue(main.settingsViewController.view.isHidden)
        XCTAssertFalse(try rail().isHidden, "the rail stays")
        XCTAssertEqual(main.firstSwipePage, 1, "swiping right past the first workspace goes nowhere")
    }

    func testNarrowingToTheRailFromSettingsReturnsToTheWorkspace() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        main.selectWorkspaceAndPage(second)
        main.enterSettings()
        harness.spin()
        XCTAssertTrue(model.state.isSettingsSelected)
        harness.window.setContentSize(NSSize(width: 52, height: 620))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        harness.spin()
        XCTAssertFalse(model.state.isSettingsSelected)
        XCTAssertEqual(model.currentWorkspace.id, second, "back to the workspace you came from")
        XCTAssertFalse(try rail().isHidden)
    }

    func testSwipingPagesClampsAtTheFirstPage() {
        XCTAssertEqual(ScrollWheelPageController.clampPage(0, firstPage: 1, pageCount: 4), 1)
        XCTAssertEqual(ScrollWheelPageController.clampPage(0, firstPage: 0, pageCount: 4), 0)
        XCTAssertEqual(ScrollWheelPageController.clampPage(9, firstPage: 1, pageCount: 4), 3)
    }

    // MARK: Settings is app settings at every width

    func testTheSettingsPageListsNoWorkspaces() throws {
        _ = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        main.enterSettings()
        harness.spin()
        let page = main.settingsViewController.view
        let labels = page.descendants(of: NSTextField.self).map(\.stringValue)
        XCTAssertFalse(labels.contains("Workspaces"), "no WORKSPACES section")
        XCTAssertFalse(labels.contains("Second"))
        XCTAssertTrue(page.descendants(of: NSCollectionView.self).isEmpty, "no workspace rows")
        let names = page.descendants(of: NSView.self).compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(names.contains("New workspace"))
    }

    func testTheFirstTabOnTheSettingsPageLandsOnThePlacementCards() throws {
        let settings = SettingsContentViewController()
        settings.appModel = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentViewController = settings
        window.makeKeyAndOrderFront(nil)
        harness.spin(0.2)
        let saved = FocusRing.currentEvent
        defer { FocusRing.currentEvent = saved }
        FocusRing.currentEvent = { nil }
        window.makeFirstResponder(nil)
        window.recalculateKeyViewLoop()
        window.selectNextKeyView(nil)
        XCTAssertTrue(window.firstResponder === settings.sheet.placementPicker, "first Tab: \(String(describing: window.firstResponder))")
    }

    func testCommandCommaAndEscLeaveTheSettingsPageForWhereYouCameFrom() {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        main.selectWorkspaceAndPage(second)
        main.toggleSettings()
        XCTAssertTrue(model.state.isSettingsSelected)
        main.toggleSettings()
        XCTAssertFalse(model.state.isSettingsSelected, "⌘, leaves the page too")
        XCTAssertEqual(model.currentWorkspace.id, second)
        main.enterSettings()
        XCTAssertTrue(main.handleEscape())
        XCTAssertFalse(model.state.isSettingsSelected, "Esc leaves the page")
        XCTAssertEqual(model.currentWorkspace.id, second)
    }

    func testTheTitleGearLeavesSettingsToo() {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        harness.host(width: 320)
        main.selectWorkspaceAndPage(second)
        main.titleSettingsButton.performClick(nil)
        XCTAssertTrue(model.state.isSettingsSelected)
        main.titleSettingsButton.performClick(nil)
        XCTAssertFalse(model.state.isSettingsSelected, "the gear goes back")
        XCTAssertEqual(model.currentWorkspace.id, second)
    }

    func testTheTitlePlusHidesOnSettings() {
        harness.host(width: 320)
        XCTAssertFalse(main.titleAddButton.isHidden)
        main.enterSettings()
        harness.spin()
        XCTAssertTrue(main.titleAddButton.isHidden, "New… would add to a workspace you can't see")
        main.toggleSettings()
        harness.spin()
        XCTAssertFalse(main.titleAddButton.isHidden)
    }

    // MARK: New workspace through the editor

    func testANewWorkspaceIsCreatedOnlyWhenCommitted() throws {
        harness.host(width: 52)
        let before = model.workspaces.map(\.id)
        main.promptCreateWorkspace()
        XCTAssertTrue(editor.isNew, "the editor opens on a workspace that doesn't exist yet")
        XCTAssertEqual(editor.editor.nameField.stringValue, "")
        XCTAssertEqual(model.workspaces.map(\.id), before, "nothing is created until it's committed")
        editor.editor.nameField.stringValue = "Reading"
        editor.editor.onRename?("Reading")
        editor.editor.onColor?(.ember)
        XCTAssertEqual(model.workspaces.count, before.count)
        editor.editor.onCommit?()
        XCTAssertEqual(model.workspaces.count, before.count + 1)
        let created = try XCTUnwrap(model.workspaces.last)
        XCTAssertEqual(created.name, "Reading")
        XCTAssertEqual(created.colorId, .ember)
        XCTAssertEqual(model.currentWorkspace.id, created.id, "you land in it")
        XCTAssertFalse(model.state.isSettingsSelected)
    }

    func testEscOnANewWorkspaceCreatesNothing() throws {
        harness.host(width: 52)
        let before = model.workspaces.map(\.id)
        main.promptCreateWorkspace()
        editor.editor.onRename?("Half typed")
        editor.editor.onEscape?()
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(model.workspaces.map(\.id), before, "Esc creates nothing")
    }

    func testCommandNInTheRailUsesTheSameEditor() {
        harness.host(width: 52)
        let before = model.workspaces.count
        main.promptCreateWorkspace()
        XCTAssertTrue(editor.isNew)
        XCTAssertEqual(model.workspaces.count, before)
        XCTAssertFalse(model.state.isSettingsSelected, "no trip to Settings")
        editor.editor.onCommit?()
        XCTAssertEqual(model.workspaces.count, before + 1)
        XCTAssertEqual(model.workspaces.last?.name, "Untitled", "an empty name becomes Untitled")
    }

    func testCommandNInTheListUsesTheSameEditor() {
        harness.host(width: 320)
        let before = model.workspaces.count
        main.promptCreateWorkspace()
        XCTAssertTrue(editor.isNew)
        XCTAssertEqual(model.workspaces.count, before)
        XCTAssertFalse(main.isWorkspaceStripRenaming, "no inline tab rename")
    }

    func testSwipingPastTheLastWorkspaceOpensTheNewWorkspaceEditor() {
        harness.host(width: 320)
        let before = model.workspaces.count
        let last = model.currentWorkspace.id
        main.pageSwipe.pagerDidSnapToPage(main.totalPageCount() - 1)
        XCTAssertTrue(editor.isNew)
        XCTAssertEqual(model.workspaces.count, before, "nothing is created by the swipe itself")
        XCTAssertFalse(main.isWorkspaceStripRenaming)
        editor.editor.onEscape?()
        XCTAssertEqual(model.workspaces.count, before)
        XCTAssertEqual(main.shownPage, main.currentPageIndex(), "the pager snaps back")
        XCTAssertEqual(model.currentWorkspace.id, last)
    }

    func testMoveToNewWorkspaceMovesTheItemsOnCommit() throws {
        harness.host(width: 320)
        let link = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        let source = model.currentWorkspace.id
        main.moveToNewWorkspace([link])
        XCTAssertTrue(editor.isNew)
        XCTAssertNotNil(model.nodeById(link))
        editor.editor.onRename?("Later")
        editor.editor.onCommit?()
        let created = try XCTUnwrap(model.workspaces.first { $0.name == "Later" })
        XCTAssertEqual(created.items.map(\.id), [link])
        XCTAssertFalse(model.workspaces.first { $0.id == source }!.items.contains { $0.id == link })
    }
}
