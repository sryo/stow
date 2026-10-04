import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Esc during an inline rename cancels it (tab strip and list rows), and the list
/// keeps keyboard focus once a rename ends.
@MainActor
final class RenameEscapeTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeWindow(width: CGFloat = 400, height: CGFloat = 200) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func fieldEditor(in window: NSWindow) -> NSTextView? {
        window.firstResponder as? NSTextView
    }

    /// Replaces the field's text the way typing does, through the field editor.
    private func type(_ text: String, in editor: NSTextView) {
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    // MARK: - Tab strip

    func testEscInTheTabStripDoesNotSaveTheTypedName() {
        let window = makeWindow()
        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
        window.contentView?.addSubview(strip)
        let id = UUID()
        strip.workspaces = [.init(id: id, name: "Inbox", colorId: .ocean)]
        strip.selectedWorkspaceId = id
        var renamed: String?
        strip.onWorkspaceRename = { renamed = $1 }
        strip.beginInlineRename(workspaceId: id)
        guard let editor = fieldEditor(in: window) else { return XCTFail("the rename field never took focus") }
        type("QQ", in: editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin()
        XCTAssertNil(renamed, "Esc in the tab strip saved \(renamed ?? "")")
        XCTAssertFalse(window.firstResponder is NSTextView, "Esc left the tab in edit mode")
        window.orderOut(nil)
    }

    func testReturnInTheTabStripStillSaves() {
        let window = makeWindow()
        let strip = WorkspaceStripView(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
        window.contentView?.addSubview(strip)
        let id = UUID()
        strip.workspaces = [.init(id: id, name: "Inbox", colorId: .ocean)]
        strip.selectedWorkspaceId = id
        var renamed: String?
        strip.onWorkspaceRename = { renamed = $1 }
        strip.beginInlineRename(workspaceId: id)
        guard let editor = fieldEditor(in: window) else { return XCTFail("the rename field never took focus") }
        type("Reading", in: editor)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin()
        XCTAssertEqual(renamed, "Reading")
        window.orderOut(nil)
    }

    // MARK: - Rows

    func testEscInARowRenameCancelsAndRestoresTheTitle() {
        let window = makeWindow()
        let field = InlineEditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        window.contentView?.addSubview(field)
        field.text = "Example"
        var committed: String?
        var cancelled = false
        field.beginInlineRename(onCommit: { committed = $0 }, onCancel: { cancelled = true })
        spin()
        guard let editor = fieldEditor(in: window) else { return XCTFail("the rename field never took focus") }
        type("QQ", in: editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin()
        XCTAssertNil(committed, "Esc in a row saved \(committed ?? "")")
        XCTAssertTrue(cancelled, "Esc never cancelled the row rename")
        XCTAssertFalse(field.isEditing, "Esc left the row editing")
        XCTAssertEqual(field.text, "Example")
        window.orderOut(nil)
    }

    // MARK: - List focus after a rename

    private func renameFirstRow(endingWith command: Selector, typing text: String) -> (RedHarness, [UUID]) {
        let harness = RedHarness()
        let ids = (0..<3).map { harness.model.addLink(urlString: "https://site\($0).example", title: "Site \($0)", parentId: nil) }
        harness.host(width: 400)
        let list = harness.nodeList
        list.focusList()
        let f2 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120)!
        _ = list.handleListKey(f2)
        harness.spin(0.1)
        if let editor = harness.window.firstResponder as? NSTextView {
            type(text, in: editor)
            editor.doCommand(by: command)
        } else {
            XCTFail("F2 never started a rename")
        }
        harness.spin(0.1)
        return (harness, ids)
    }

    func testDownArrowWorksRightAfterReturnEndsARename() {
        let (harness, _) = renameFirstRow(endingWith: #selector(NSResponder.insertNewline(_:)), typing: "Renamed")
        defer { harness.tearDown() }
        let collection = harness.nodeList.view.descendants(of: NSCollectionView.self).first
        XCTAssertNil(harness.nodeList.inlineRenameNodeId)
        XCTAssertTrue(harness.window.firstResponder === collection, "after Return the list lost keyboard focus, so ↓ does nothing")
    }

    func testEscInAListRowKeepsTheOldTitleAndTheFocus() {
        let (harness, ids) = renameFirstRow(endingWith: #selector(NSResponder.cancelOperation(_:)), typing: "QQ")
        defer { harness.tearDown() }
        let collection = harness.nodeList.view.descendants(of: NSCollectionView.self).first
        XCTAssertNil(harness.nodeList.inlineRenameNodeId, "Esc left the row editing")
        if case .link(let link) = harness.model.currentWorkspace.items.first(where: { $0.id == ids[0] }) {
            XCTAssertEqual(link.title, "Site 0", "Esc saved the typed title")
        }
        XCTAssertTrue(harness.window.firstResponder === collection, "after Esc the list lost keyboard focus")
    }

    func testARenameEndedByFocusMovingElsewhereLeavesFocusThere() {
        let harness = RedHarness()
        defer { harness.tearDown() }
        _ = harness.model.addLink(urlString: "https://site.example", title: "Site", parentId: nil)
        harness.host(width: 400)
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        harness.window.contentView?.addSubview(other)
        let list = harness.nodeList
        list.focusList()
        let f2 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120)!
        _ = list.handleListKey(f2)
        harness.spin(0.1)
        XCTAssertNotNil(list.inlineRenameNodeId, "precondition: F2 started a rename")
        harness.window.makeFirstResponder(other)
        harness.spin(0.1)
        XCTAssertNil(list.inlineRenameNodeId)
        XCTAssertTrue((harness.window.firstResponder as? NSText)?.delegate === other,
                      "the list took focus back from the field the user moved to")
    }
}
