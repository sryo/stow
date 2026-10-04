import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Red tests from the 2026-10 review for the 52pt rail (review/red-tests.md).
@MainActor
final class ReviewRedRailTests: XCTestCase {
    private let github = Link(id: UUID(), title: "GitHub", url: "https://github.com/sryo", faviconPath: nil)

    private func dot(_ name: String) -> RailView.WorkspaceDot {
        RailView.WorkspaceDot(id: UUID(), name: name, color: .systemBlue)
    }

    private func rail(items: [Node], dots: [RailView.WorkspaceDot]? = nil) -> RailView {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        let dots = dots ?? [dot("Alpha")]
        view.configure(workspaces: dots, selectedId: dots.first?.id, colorId: .defaultColor(), items: items)
        return view
    }

    /// The glyph the real ⌘1–9 binding uses, read from the main menu.
    private func workspaceShortcutGlyph() -> String {
        let main = AppMenus.build(target: nil)
        let item = main.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Workspace 1" }
        let mods = item?.keyEquivalentModifierMask ?? []
        var glyph = ""
        if mods.contains(.control) { glyph += "⌃" }
        if mods.contains(.option) { glyph += "⌥" }
        if mods.contains(.shift) { glyph += "⇧" }
        if mods.contains(.command) { glyph += "⌘" }
        return glyph
    }

    // MARK: patterns-1 / modes-1

    func testRightClickOnARailItemHasAMenuWired() {
        let harness = RedHarness()
        defer { harness.tearDown() }
        _ = harness.model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        harness.host(width: ElasticMode.railWidth)
        guard let railView = harness.controller.view.descendants(of: RailView.self).first else {
            return XCTFail("no RailView in MainViewController")
        }
        XCTAssertNotNil(railView.onNodeMenu,
                        "patterns-1/modes-1: wireRail never sets onNodeMenu, so right-clicking a rail link or folder does nothing")
    }

    // MARK: patterns-13

    func testRailDotTooltipNamesTheRealWorkspaceShortcut() {
        let view = rail(items: [], dots: [dot("Alpha")])
        let tip = view.descendants(of: NSButton.self).compactMap(\.toolTip).first { $0.hasPrefix("Alpha") }
        let expected = workspaceShortcutGlyph() + "1"
        XCTAssertEqual(expected, "⌘1", "precondition: AppMenus binds Workspace 1 to ⌘1")
        XCTAssertTrue(tip?.contains(expected) == true,
                      "patterns-13: rail dot tooltip is \(tip ?? "nil"), but the shortcut is \(expected)")
    }

    // MARK: patterns-9 / modes-14

    func testALetterTileHasTheSameColorInTheRailAndTheTabline() {
        let rail = RailCell.tileColor(for: github).usingColorSpace(.sRGB)!
        let tabline = TablineGlyph.tileColor(for: TablineGlyph.host(of: github.url)).usingColorSpace(.sRGB)!
        let distance = abs(rail.redComponent - tabline.redComponent)
            + abs(rail.greenComponent - tabline.greenComponent)
            + abs(rail.blueComponent - tabline.blueComponent)
        XCTAssertLessThan(distance, 0.02,
                          "patterns-9/modes-14: github.com is \(rail) in the rail (FNV-1a hue) but \(tabline) in the Tabline (djb2 palette)")
    }

    func testALetterTileShowsTheSameLettersInTheRailAndTheTabline() {
        let rail = RailCell.assignLetters([github])[github.id]
        let tabline = TablineGlyph.letter(title: github.title, host: TablineGlyph.host(of: github.url))
        XCTAssertEqual(rail, tabline, "modes-14: the rail tile reads \(rail ?? "nil") and the Tabline tile reads \(tabline)")
    }

    // MARK: modes-17

    func testATaskFiledInAFolderStillReachesTheRail() {
        let task = TaskItem(id: UUID(), title: "Reply", isCompleted: false, dueDate: nil, notes: nil, createdAt: Date())
        let folder = Folder(id: UUID(), name: "Inbox", children: [.task(task)], isExpanded: true)
        let view = rail(items: [.folder(folder)])
        let tasksCells = view.descendants(of: RailCell.self).filter { if case .tasks = $0.kind { return true }; return false }
        XCTAssertEqual(tasksCells.count, 1,
                       "modes-17: RailView.rebuildCells collects only top-level tasks, while the Tabline pocket recurses into folders")
    }

    // MARK: modes-8

    func testTheRailAcceptsAURLDraggedFromTheBrowser() {
        let view = rail(items: [.link(github)])
        let types = Set(([view] + view.descendants(of: NSView.self)).flatMap(\.registeredDraggedTypes))
        XCTAssertTrue(types.contains(.URL), "modes-8: RailView registers no drag types, so a URL from the browser can't be dropped")
    }

    // MARK: modes-21

    func testRailCellIsAVoiceOverButton() {
        let cell = RailCell(kind: .link(github, letters: "GH"))
        XCTAssertTrue(cell.isAccessibilityElement(), "modes-21: RailCell sets a label but never setAccessibilityElement(true)")
        XCTAssertEqual(cell.accessibilityRole(), .button, "modes-21: RailCell has no role, so VoiceOver can't press it")
    }

    func testRailCellSaysWhenItsLinkIsOpen() {
        let cell = RailCell(kind: .link(github, letters: "GH"))
        cell.isOpen = true
        let label = cell.accessibilityLabel() ?? ""
        XCTAssertTrue(label.localizedCaseInsensitiveContains("open"),
                      "modes-21: the open dot is visual only; the label stays \"\(label)\"")
    }
}
