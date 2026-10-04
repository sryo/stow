import AppKit
import XCTest
@testable import StowCore

// MARK: - Dismiss policy

@MainActor
final class FlyoutDismissPolicyTests: XCTestCase {
    func testClicksInTheStackTheHostMenusPopoversAndTheColorPanelStayInside() {
        typealias P = FlyoutDismissPolicy
        XCTAssertFalse(P.clickCloses(inStack: true, inHost: false, isColorPanel: false, windowClassName: "FlyoutPanel"))
        XCTAssertFalse(P.clickCloses(inStack: false, inHost: true, isColorPanel: false, windowClassName: "NSWindow"))
        XCTAssertFalse(P.clickCloses(inStack: false, inHost: false, isColorPanel: true, windowClassName: "NSColorPanel"))
        XCTAssertFalse(P.clickCloses(inStack: false, inHost: false, isColorPanel: false, windowClassName: "NSMenuWindowManagerWindow"))
        XCTAssertFalse(P.clickCloses(inStack: false, inHost: false, isColorPanel: false, windowClassName: "_NSPopoverWindow"))
    }

    func testAClickInAnotherWindowCloses() {
        XCTAssertTrue(FlyoutDismissPolicy.clickCloses(inStack: false, inHost: false, isColorPanel: false, windowClassName: "NSWindow"))
        XCTAssertTrue(FlyoutDismissPolicy.clickCloses(inStack: false, inHost: false, isColorPanel: false, windowClassName: nil))
    }

    func testAPushedChildCountsAsInside() {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let root = FlyoutPanel()
        let child = FlyoutPanel()
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let stack = [root, child]
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(window: child, stack: stack, host: host))
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(window: root, stack: stack, host: host))
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(window: host, stack: stack, host: host))
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(window: NSColorPanel.shared, stack: stack, host: host))
        XCTAssertTrue(FlyoutDismissPolicy.clickCloses(window: other, stack: stack, host: host))
    }

    func testPopoversCountAsInsideAndOtherWindowsDont() {
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(inStack: false, inHost: false, isColorPanel: false,
                                                       windowClassName: "_NSPopoverWindow"))
        XCTAssertTrue(FlyoutDismissPolicy.clickCloses(inStack: false, inHost: false, isColorPanel: false,
                                                      windowClassName: "NSWindow"))
    }
}

// MARK: - Controller stack

@MainActor
final class FlyoutControllerTests: XCTestCase {
    private var window: NSWindow!
    private var flyouts: FlyoutController!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        flyouts = FlyoutController()
    }

    override func tearDown() async throws {
        flyouts.closeAll()
        window.close()
        flyouts = nil
        window = nil
    }

    private func content() -> NSView { RailFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 120)) }

    private func showRoot(_ id: String, _ panel: FlyoutPanel = FlyoutPanel()) -> FlyoutPanel {
        flyouts.show(panel, id: id, content: content(), size: NSSize(width: 200, height: 120),
                     anchor: NSRect(x: 220, y: 500, width: 30, height: 30),
                     edge: .beside(column: window.frame), topInset: 20, parent: window)
        return panel
    }

    private func pushChild(_ id: String, _ panel: FlyoutPanel = FlyoutPanel()) -> FlyoutPanel {
        flyouts.push(panel, id: id, content: content(), size: NSSize(width: 200, height: 120),
                     anchor: NSRect(x: 600, y: 480, width: 60, height: 14), topInset: 20)
        return panel
    }

    func testPushStacksAChildBesideTheTopPanel() {
        let root = showRoot("sheet")
        let child = pushChild("shortcuts")
        XCTAssertEqual(flyouts.openIds, ["sheet", "shortcuts"])
        XCTAssertTrue(root.isVisible)
        XCTAssertTrue(child.isVisible)
        XCTAssertGreaterThanOrEqual(child.frame.minX, root.frame.maxX, "the child opens beside its parent, not over it")
        XCTAssertTrue(flyouts.isOpen)
    }

    func testCloseAllEmptiesTheStack() {
        let root = showRoot("sheet")
        let child = pushChild("shortcuts")
        flyouts.closeAll()
        XCTAssertEqual(flyouts.openIds, [])
        XCTAssertFalse(root.isVisible)
        XCTAssertFalse(child.isVisible)
        XCTAssertFalse(flyouts.isOpen)
    }

    func testShowingAnotherRootClosesTheFirstAndItsChildren() {
        let sheet = showRoot("sheet")
        let child = pushChild("shortcuts")
        let editor = showRoot("editor")
        XCTAssertEqual(flyouts.openIds, ["editor"])
        XCTAssertFalse(sheet.isVisible)
        XCTAssertFalse(child.isVisible)
        XCTAssertTrue(editor.isVisible)
    }

    func testShowingTheSameRootAgainRepositionsItAndKeepsItsChild() {
        let sheet = FlyoutPanel()
        _ = showRoot("sheet", sheet)
        _ = pushChild("shortcuts")
        _ = showRoot("sheet", sheet)
        XCTAssertEqual(flyouts.openIds, ["sheet", "shortcuts"])
    }

    func testPushingAgainReplacesWhateverWasAboveTheParent() {
        _ = showRoot("sheet")
        let first = pushChild("shortcuts")
        _ = pushChild("other")
        XCTAssertEqual(flyouts.openIds, ["sheet", "shortcuts", "other"])
        flyouts.close(id: "shortcuts")
        XCTAssertEqual(flyouts.openIds, ["sheet"])
        XCTAssertFalse(first.isVisible)
    }

    func testToggleClosesAnOpenFlyoutAndOpensAClosedOne() {
        var opened = 0
        flyouts.toggle(id: "sheet") { opened += 1; _ = self.showRoot("sheet") }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(flyouts.openIds, ["sheet"])
        flyouts.toggle(id: "sheet") { opened += 1 }
        XCTAssertEqual(opened, 1, "a second toggle closes instead of reopening")
        XCTAssertEqual(flyouts.openIds, [])
    }

    func testEscInAPushedChildClosesOnlyTheChild() {
        let root = showRoot("sheet")
        let child = pushChild("shortcuts")
        child.cancelOperation(nil)
        XCTAssertEqual(flyouts.openIds, ["sheet"])
        XCTAssertTrue(root.isVisible)
        XCTAssertFalse(child.isVisible)
    }

    func testEscRunsTheRootsOwnHandler() {
        var escaped = false
        let root = FlyoutPanel()
        flyouts.show(root, id: "editor", content: content(), size: NSSize(width: 200, height: 120),
                     anchor: NSRect(x: 220, y: 500, width: 30, height: 30), edge: .beside(column: window.frame),
                     topInset: 20, parent: window, onEscape: { escaped = true })
        root.cancelOperation(nil)
        XCTAssertTrue(escaped)
    }

    func testBelowPlacesTheCardUnderItsAnchorWithTheArrowOnTop() {
        let panel = FlyoutPanel()
        let anchor = NSRect(x: 300, y: 600, width: 40, height: 20)
        flyouts.show(panel, id: "chip", content: content(), size: NSSize(width: 200, height: 120),
                     anchor: anchor, edge: .below, topInset: 0, parent: window)
        XCTAssertLessThanOrEqual(panel.frame.maxY, anchor.minY, "the card hangs below the anchor")
        XCTAssertEqual(panel.frame.height, 120 + FlyoutPanel.arrowDepth, accuracy: 0.5)
    }
}

// MARK: - All shortcuts

@MainActor
final class AllShortcutsTests: XCTestCase {
    func testEveryStowMenuShortcutIsListed() {
        let rows = AllShortcuts.rows()
        let keys = Set(rows.map(\.keys))
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard !item.keyEquivalent.isEmpty, !AllShortcuts.isStandard(item) else { continue }
                if item.title.hasPrefix("Workspace ") { continue }
                let display = AllShortcuts.display(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                XCTAssertTrue(keys.contains(display), "\(item.title) (\(display)) is missing from All shortcuts")
            }
        }
        walk(AppMenus.build(target: nil))
        XCTAssertTrue(keys.contains("⌘1–9"))
    }

    func testListKeysAreIncluded() {
        let keys = AllShortcuts.rows().map(\.keys)
        for key in ["⌘⌫", "F2", "/", "⌥↩"] {
            XCTAssertTrue(keys.contains(key), "\(key) is missing from All shortcuts")
        }
        XCTAssertFalse(AllShortcuts.rows().contains { $0.title == "Open item by letter" },
                       "letters only open rows in ⌘J jump mode")
    }

    func testKeyEquivalentsReadLikeTheMenu() {
        XCTAssertEqual(AllShortcuts.display(key: "N", modifiers: [.command, .shift]), "⇧⌘N")
        XCTAssertEqual(AllShortcuts.display(key: "\t", modifiers: [.control, .shift]), "⌃⇧⇥")
        XCTAssertEqual(AllShortcuts.display(key: "t", modifiers: [.command, .option]), "⌥⌘T")
        XCTAssertEqual(AllShortcuts.display(key: ",", modifiers: [.command]), "⌘,")
    }

    func testEveryShortcutAndNameShowsInFull() {
        let view = AllShortcutsView()
        view.frame.size = view.preferredSize
        view.layoutSubtreeIfNeeded()
        let labels = view.subviews.compactMap { $0 as? NSTextField }.filter { $0 !== view.note }
        XCTAssertGreaterThan(labels.count, 20)
        for label in labels {
            let needed = ceil(label.attributedStringValue.size().width) + 4
            XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, needed, "“\(label.stringValue)” is cut to “…”")
            XCTAssertGreaterThanOrEqual(label.frame.minX, 0)
        }
    }

    func testTheFootnoteIsNotCutOff() {
        let view = AllShortcutsView()
        view.frame.size = view.preferredSize
        view.layoutSubtreeIfNeeded()
        let note = view.note
        let needed = note.attributedStringValue.boundingRect(with: NSSize(width: note.frame.width - 4, height: 200),
                                                             options: [.usesLineFragmentOrigin]).height
        XCTAssertGreaterThanOrEqual(note.frame.height + 0.5, ceil(needed))
        XCTAssertLessThanOrEqual(note.frame.maxY, view.preferredSize.height)
    }
}
