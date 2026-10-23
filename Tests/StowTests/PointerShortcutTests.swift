import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Middle-click opens a link behind Stow; a double-click on the list's empty space
/// stows the front tab.
@MainActor
final class PointerShortcutTests: XCTestCase {
    private var harness: RedHarness!

    override func setUp() async throws { harness = RedHarness() }

    override func tearDown() async throws {
        harness.tearDown()
        harness = nil
    }

    private func item(of id: UUID) -> Int? {
        (0..<50).first { harness.nodeList.visibleNode(at: $0)?.id == id }
    }

    func testMiddleClickingALinkOpensItInTheBackground() throws {
        let id = harness.model.addLink(urlString: "https://example.com/a", title: "A", parentId: nil)
        harness.host(width: 400)
        var opened: [URL] = []
        harness.controller.links.openBehind = { url, _ in opened.append(url) }

        harness.nodeList.middleClicked(item: try XCTUnwrap(item(of: id)))
        XCTAssertEqual(opened, [URL(string: "https://example.com/a")!])
    }

    func testMiddleClickingAFolderDoesNothing() throws {
        let id = harness.model.addFolder(name: "F", parentId: nil)
        harness.host(width: 400)
        var opened: [URL] = []
        harness.controller.links.openBehind = { url, _ in opened.append(url) }

        harness.nodeList.middleClicked(item: try XCTUnwrap(item(of: id)))
        XCTAssertEqual(opened, [])
    }

    func testDoubleClickingEmptySpaceStowsTheFrontTab() {
        harness.host(width: 400)
        var stowed = 0
        harness.controller.links.stowFront = { stowed += 1 }
        harness.nodeList.backgroundDoubleClicked()
        XCTAssertEqual(stowed, 1)
    }
}

@MainActor
final class RailMiddleClickTests: XCTestCase {
    func testMiddleClickingARailLinkOpensItInTheBackground() throws {
        let link = Link(id: UUID(), title: "A", url: "https://example.com/a", faviconPath: nil)
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        let ws = RailView.WorkspaceEntry(id: UUID(), name: "Alpha", colorId: .ocean)
        view.configure(workspaces: [ws], selectedId: ws.id, colorId: .defaultColor(), items: [.link(link)])
        var opened: [UUID] = []
        view.onOpenLinkInBackground = { opened.append($0.id) }
        let cell = try XCTUnwrap(view.descendants(of: RailCell.self).first { $0.node?.id == link.id })

        let cgEvent = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                                            mouseCursorPosition: .zero, mouseButton: .center))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(event.buttonNumber, 2)
        cell.otherMouseUp(with: event)
        XCTAssertEqual(opened, [link.id])
    }
}

@MainActor
final class SearchSubmitTests: XCTestCase {
    func testReturnInTheSearchFieldRunsABang() throws {
        let harness = RedHarness()
        defer { harness.tearDown() }
        harness.host(width: 400)
        var opened: [URL] = []
        harness.controller.links.openBehind = { url, _ in opened.append(url) }
        harness.controller.links.openFront = { url in opened.append(url) }

        let field = try XCTUnwrap(harness.controller.searchField.descendants(of: NSTextField.self).first)
        harness.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(harness.window.makeFirstResponder(field))
        field.currentEditor()?.insertText("!g stow")
        harness.spin()
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: harness.window.windowNumber, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))
        harness.window.sendEvent(returnKey)
        harness.spin()

        XCTAssertEqual(opened.map(\.absoluteString), ["https://www.google.com/search?q=stow"])
        XCTAssertEqual(harness.controller.searchField.text, "")
    }
}
