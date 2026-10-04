import AppKit
import XCTest
@testable import StowCore
import StowShared

/// C3, C5 and B11: rename, Edit URL, due date and the snippet editor open as flyouts
/// beside the item, and the rail's create flows open them instead of renaming rows in
/// the hidden list.
@MainActor
final class FlyoutEditorsTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        harness.controller?.itemFlyouts.closeAll()
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func anchorWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let anchor = NSView(frame: NSRect(x: 20, y: 200, width: 200, height: 24))
        window.contentView?.addSubview(anchor)
        return (window, anchor)
    }

    private func type(_ text: String, into flyout: TextFieldFlyout) {
        flyout.field.stringValue = text
    }

    private func press(_ selector: Selector, in flyout: TextFieldFlyout) {
        _ = flyout.control(flyout.field, textView: NSTextView(), doCommandBy: selector)
    }

    // MARK: TextFieldFlyout

    func testReturnSavesAndClosesTheTextFieldFlyout() throws {
        let (window, anchor) = anchorWindow()
        defer { window.orderOut(nil) }
        let flyouts = ItemFlyouts()
        var saved: String?
        let flyout = try XCTUnwrap(TextFieldFlyout.present(in: flyouts, title: "Rename", value: "Old", placeholder: "Name",
                                                           from: anchor, onSave: { saved = $0 }))
        XCTAssertTrue(flyouts.panel(for: .text).isVisible)
        XCTAssertEqual(flyout.saveButton.style, .primary)
        type("  New name ", into: flyout)
        press(#selector(NSResponder.insertNewline(_:)), in: flyout)
        XCTAssertEqual(saved, "New name")
        XCTAssertFalse(flyouts.panel(for: .text).isVisible)
    }

    func testEscapeCancelsTheTextFieldFlyout() throws {
        let (window, anchor) = anchorWindow()
        defer { window.orderOut(nil) }
        let flyouts = ItemFlyouts()
        var saved: String?
        var cancelled = false
        let flyout = try XCTUnwrap(TextFieldFlyout.present(in: flyouts, title: "Rename", value: "Old", placeholder: "Name",
                                                           from: anchor, onSave: { saved = $0 }, onCancel: { cancelled = true }))
        type("Changed", into: flyout)
        flyouts.panel(for: .text).cancelOperation(nil)
        XCTAssertNil(saved)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(flyouts.panel(for: .text).isVisible)
    }

    func testEditURLIsAFlyoutBesideTheRowNotAModalAlert() throws {
        let id = model.addLink(urlString: "https://example.com/old", title: "Old", parentId: nil)
        harness.host(width: 300)
        harness.window.orderFront(nil)
        var edited: (UUID, String)?
        harness.nodeList.onLinkUrlEdited = { edited = ($0, $1) }
        let flyout = try XCTUnwrap(harness.nodeList.presentEditURLFlyout(for: id))
        XCTAssertEqual(flyout.field.stringValue, "https://example.com/old")
        let panel = harness.nodeList.flyouts.panel(for: .text)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.frame.intersects(harness.window.frame.insetBy(dx: 8, dy: 0)), "it flies out beside the window")
        type("https://example.com/new", into: flyout)
        flyout.saveButton.performAction()
        XCTAssertEqual(edited?.0, id)
        XCTAssertEqual(edited?.1, "https://example.com/new")
    }

    func testRenameFlyoutRenamesTheItem() throws {
        let id = model.addLink(urlString: "https://example.com", title: "Old", parentId: nil)
        harness.host(width: 700)
        harness.window.orderFront(nil)
        let flyout = try XCTUnwrap(harness.nodeList.presentRenameFlyout(for: id))
        XCTAssertEqual(flyout.field.stringValue, "Old")
        type("New", into: flyout)
        flyout.saveButton.performAction()
        XCTAssertEqual(model.nodeById(id)?.displayName, "New")
    }

    // MARK: Due date

    func testDueDateQuickPickThenSaveCommitsAndCloses() throws {
        let (window, anchor) = anchorWindow()
        defer { window.orderOut(nil) }
        let flyouts = ItemFlyouts()
        var committed: Date??
        let editor = try XCTUnwrap(DueDateFlyout.present(in: flyouts, title: "Task", dueDate: nil, from: anchor) { committed = $0 })
        XCTAssertEqual(editor.quickPicks.accessibilityLabel(), "Quick picks")
        editor.pickQuick(1)
        editor.saveButton.performAction()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        XCTAssertEqual(committed, .some(tomorrow))
        XCTAssertFalse(flyouts.panel(for: .dueDate).isVisible)
    }

    func testDueDateEscapeCancelsAndClearRemoves() throws {
        let (window, anchor) = anchorWindow()
        defer { window.orderOut(nil) }
        let flyouts = ItemFlyouts()
        var committed: Date??
        _ = try XCTUnwrap(DueDateFlyout.present(in: flyouts, title: "Task", dueDate: Date(), from: anchor) { committed = $0 })
        flyouts.panel(for: .dueDate).cancelOperation(nil)
        XCTAssertNil(committed, "Esc commits nothing")
        XCTAssertFalse(flyouts.panel(for: .dueDate).isVisible)

        let again = try XCTUnwrap(DueDateFlyout.present(in: flyouts, title: "Task", dueDate: Date(), from: anchor) { committed = $0 })
        XCTAssertTrue(again.clearButton.isEnabled)
        again.clearButton.performAction()
        XCTAssertEqual(committed, .some(nil))
    }

    func testTheListsDueDateOpensTheFlyout() {
        let id = model.addTask(title: "Task", parentId: nil)
        harness.host(width: 300)
        harness.window.orderFront(nil)
        harness.nodeList.onTaskDueDateRequested?(id)
        XCTAssertTrue(harness.controller.itemFlyouts.panel(for: .dueDate).isVisible)
    }

    // MARK: Snippet editor

    func testTheSnippetEditorIsOneReusedFlyoutBesideTheRow() throws {
        let a = model.addSnippet(title: "A", content: "echo a", language: "Shell", parentId: nil)
        let b = model.addSnippet(title: "B", content: "echo b", language: nil, parentId: nil)
        harness.host(width: 300)
        harness.window.orderFront(nil)
        harness.nodeList.onSnippetEditRequested?(a)
        let panel = harness.controller.itemFlyouts.panel(for: .snippet)
        XCTAssertTrue(panel.isVisible)
        let first = try XCTUnwrap(panel.content as? SnippetEditorView)
        XCTAssertEqual(first.frame.width, 360, accuracy: 1)
        XCTAssertEqual(first.frame.height, 300, accuracy: 1)
        XCTAssertFalse(NSApp.windows.contains { $0.title.hasPrefix("Edit snippet") && $0.isVisible }, "no titled panel")
        harness.nodeList.onSnippetEditRequested?(b)
        XCTAssertTrue(panel.content === first, "one editor, reused")
        first.contentText = "echo bee"
        first.saveButton.performAction()
        guard case .snippet(let snippet)? = model.nodeById(b) else { return XCTFail("no snippet") }
        XCTAssertEqual(snippet.content, "echo bee")
        XCTAssertFalse(panel.isVisible)
    }

    // MARK: Rail hooks and create flows (B11)

    func testTheRailsEditHooksAreWired() {
        harness.host(width: ElasticMode.railWidth)
        guard let rail = harness.controller.view.descendants(of: RailView.self).first else { return XCTFail("no rail") }
        XCTAssertNotNil(rail.onEditSnippet)
        XCTAssertNotNil(rail.onSetDueDate)
        XCTAssertNotNil(rail.onNewTask)
        XCTAssertNotNil(rail.onDropText)
    }

    func testANewFolderInTheRailOpensTheNameFlyoutAndCancelLeavesNothing() throws {
        harness.host(width: ElasticMode.railWidth)
        harness.window.orderFront(nil)
        harness.controller.createFolderAndBeginRename(parentId: nil)
        XCTAssertNil(harness.nodeList.inlineRenameNodeId, "no rename in the hidden list")
        let panel = harness.controller.itemFlyouts.panel(for: .text)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.currentWorkspace.items.count, 1)
        panel.cancelOperation(nil)
        XCTAssertTrue(model.currentWorkspace.items.isEmpty, "no Untitled leftover")
    }

    func testANewFolderInTheRailTakesTheTypedName() throws {
        harness.host(width: ElasticMode.railWidth)
        harness.window.orderFront(nil)
        harness.controller.createFolderAndBeginRename(parentId: nil)
        let flyout = try XCTUnwrap(harness.controller.itemFlyouts.panel(for: .text).content as? TextFieldFlyout)
        type("Reading", into: flyout)
        flyout.saveButton.performAction()
        XCTAssertEqual(model.currentWorkspace.items.map(\.displayName), ["Reading"])
    }

    func testANewTaskInTheRailIsNamedInAFlyout() throws {
        harness.host(width: ElasticMode.railWidth)
        harness.window.orderFront(nil)
        guard let rail = harness.controller.view.descendants(of: RailView.self).first else { return XCTFail("no rail") }
        rail.onNewTask?()
        let flyout = try XCTUnwrap(harness.controller.itemFlyouts.panel(for: .text).content as? TextFieldFlyout)
        XCTAssertTrue(model.currentWorkspace.items.isEmpty, "nothing is added until it's named")
        type("Call back", into: flyout)
        press(#selector(NSResponder.insertNewline(_:)), in: flyout)
        XCTAssertEqual(model.currentWorkspace.items.map(\.displayName), ["Call back"])
    }

    func testNewWorkspaceInTheRailOpensTheEditorBesideThePlusDot() {
        harness.host(width: ElasticMode.railWidth)
        harness.window.orderFront(nil)
        let before = model.workspaces.count
        harness.controller.promptCreateWorkspace()
        defer { harness.controller.workspaceEditor.cancel() }
        XCTAssertEqual(model.workspaces.count, before, "nothing is created until it's named")
        XCTAssertFalse(model.state.isSettingsSelected, "the rail stays on the workspace")
        XCTAssertTrue(harness.controller.workspaceEditor.isNew, "the editor opens on the new workspace")
        XCTAssertFalse(harness.controller.isWorkspaceStripRenaming, "no rename in the hidden strip")
    }

    func testFindInTheRailWidensToTheListFirst() {
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        harness.window.orderFront(nil)
        harness.controller.focusSearch()
        harness.window.layoutIfNeeded()
        XCTAssertEqual(ElasticMode.forWidth(harness.window.contentView?.bounds.width ?? 0), .list)
    }

    func testSlashDoesNotFocusTheHiddenSearchInTheRail() {
        _ = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        XCTAssertFalse(harness.controller.acceptsListShortcuts, "/, ⌘J and ⌘-hold are off in the rail")
        harness.host(width: 300)
        XCTAssertTrue(harness.controller.acceptsListShortcuts)
    }

    // MARK: Drops (G1 prep)

    func testDroppedTextLandsWhereItWasDropped() {
        let first = model.addLink(urlString: "https://example.com/1", title: "1", parentId: nil)
        harness.host(width: 300)
        harness.nodeList.onDropText?("https://stow.invalid/dropped", nil, 0)
        guard case .link(let link)? = model.currentWorkspace.items.first else { return XCTFail("no items") }
        XCTAssertEqual(link.url, "https://stow.invalid/dropped")
        XCTAssertEqual(model.currentWorkspace.items.last?.id, first)
    }
}
