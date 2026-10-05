import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Share… shows the link in a card on the editor's own flyout stack, so it's always in
/// front of the window it came from, the Tabline's strip included.
@MainActor
final class ShareCardTests: XCTestCase {
    private var harness: RedHarness!
    private var host: NSWindow!
    private var controller: WorkspaceEditorController!

    override func setUp() async throws {
        harness = RedHarness()
        host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 500), styleMask: [.titled],
                        backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        controller = WorkspaceEditorController(model: harness.model)
    }

    override func tearDown() async throws {
        controller.close()
        host.orderOut(nil)
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func openEditor() -> UUID {
        let id = model.currentWorkspace.id
        let host = self.host!
        controller.open(id, placement: { .init(anchor: NSRect(x: 520, y: 600, width: 20, height: 20),
                                               edge: .beside(column: host.frame), parent: host) })
        return id
    }

    func testShareOpensTheCardOnTheEditorsFlyoutStack() throws {
        _ = openEditor()
        controller.editor.onShare?()
        XCTAssertTrue(controller.isShareOpen)
        XCTAssertEqual(controller.flyouts.openIds.count, 2, "the card is pushed beside the editor")
        XCTAssertTrue(controller.sharePanel.parent === host, "a child of the editor's window, so it stays in front of it")
        XCTAssertTrue(controller.sharePanel.isVisible)
        XCTAssertGreaterThanOrEqual(controller.sharePanel.frame.minX, controller.panel.frame.maxX - 1,
                                    "beside the editor, its arrow on Share…")
        let expected = try model.shareWorkspace(id: model.currentWorkspace.id)
        XCTAssertEqual(controller.shareCard.link, expected)
        XCTAssertEqual(controller.shareCard.workspaceName, model.currentWorkspace.name)
    }

    func testCopyLinkWritesTheLinkAndSaysCopied() throws {
        _ = openEditor()
        controller.editor.onShare?()
        NSPasteboard.general.clearContents()
        controller.shareCard.copyButton.performAction()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), controller.shareCard.link)
        XCTAssertEqual(controller.shareCard.copyButton.title, "Copied")
    }

    func testTheCardOffersTheSharePage() {
        _ = openEditor()
        controller.editor.onShare?()
        var opened: URL?
        controller.shareCard.openURL = { opened = $0 }
        controller.shareCard.openButton.performAction()
        XCTAssertEqual(opened?.absoluteString, controller.shareCard.link)
    }

    func testEscClosesOnlyTheCard() {
        _ = openEditor()
        controller.editor.onShare?()
        controller.sharePanel.onEscape?()
        XCTAssertFalse(controller.isShareOpen)
        XCTAssertTrue(controller.isOpen, "the editor stays")
    }

    func testClosingTheEditorClosesTheCard() {
        _ = openEditor()
        controller.editor.onShare?()
        controller.close()
        XCTAssertFalse(controller.isShareOpen)
        XCTAssertFalse(controller.sharePanel.isVisible)
    }

    func testTheShareWindowIsGone() {
        XCTAssertNil(NSClassFromString("StowCore.SharePanel"), "Share… no longer opens its own window")
    }
}
