import AppKit
import XCTest
@testable import StowCore
import StowShared

/// C4: one workspace editor, opened from the Settings rail, the Settings page, a rail
/// dot's menu and the Tabline chip's menu. G7: one active-only item count. X2: the list's
/// narrow end keeps its controls inside the window.
@MainActor
final class WorkspaceEditorControllerTests: XCTestCase {
    private var harness: RedHarness!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        harness = RedHarness()
    }

    override func tearDown() async throws {
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
        windows.forEach { $0.orderOut(nil) }
        windows = []
        harness.tearDown()
        harness = nil
    }

    private var model: AppModel { harness.model }

    private func window(width: CGFloat = 300, height: CGFloat = 500) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    private func link(_ title: String, archived: Bool = false) -> Node {
        .link(Link(id: UUID(), title: title, url: "https://\(title.lowercased()).com", faviconPath: nil, isArchived: archived))
    }

    // MARK: C4 · the shared editor

    func testTheEditorOpensBesideItsAnchorAndClosesOnCommit() {
        let host = window()
        let editor = WorkspaceEditorController(model: model)
        let id = model.currentWorkspace.id
        editor.open(id, placement: { .init(anchor: NSRect(x: 220, y: 400, width: 200, height: 28), edge: .beside(column: host.frame), parent: host) })
        XCTAssertEqual(editor.editingId, id)
        XCTAssertTrue(editor.isOpen)
        XCTAssertEqual(editor.editor.content?.id, id)
        editor.editor.onCommit?()
        XCTAssertNil(editor.editingId)
        XCTAssertFalse(editor.isOpen)
    }

    func testOpenFromTheEditorShowsThatWorkspace() {
        let host = window()
        let editor = WorkspaceEditorController(model: model)
        let id = model.currentWorkspace.id
        var opened: UUID?
        editor.onOpenWorkspace = { opened = $0 }
        editor.open(id, placement: { .init(anchor: host.frame, edge: .below, parent: host) })
        editor.editor.onOpen?()
        XCTAssertEqual(opened, id)
    }

    func testClickingASettingsPageRowOpensTheEditorForThatWorkspace() throws {
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectSettings()
        let host = window(width: 300, height: 600)
        let page = SettingsContentViewController()
        host.contentViewController = page
        page.appModel = model
        host.setContentSize(NSSize(width: 300, height: 600))
        host.layoutIfNeeded()
        page.view.layoutSubtreeIfNeeded()
        let rows = page.view.descendants(of: WorkspaceRowView.self)
        XCTAssertEqual(rows.count, 2)
        let row = try XCTUnwrap(rows.first { $0.accessibilityLabel()?.hasPrefix("Second") == true })
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        row.mouseDown(with: click)
        XCTAssertEqual(page.workspaceEditor?.editingId, second, "C4: a row click opens the shared editor beside the row")
        page.workspaceEditor?.close()
    }

    func testTheSettingsPageRowHasNoMenusOfItsOwn() {
        let row = WorkspaceRowView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        row.configure(.init(name: "Home", colorId: .ocean, iconLinks: [], opensIn: nil, itemCount: 0, position: 1, total: 1, canDelete: false))
        let buttons = row.descendants(of: NSControl.self).compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(buttons.contains("Workspace menu"), "C4: the “…” menu button is gone; the row opens the editor")
        let actions = (row.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertFalse(actions.contains("Change color"), "C4: colour is in the editor, not a menu")
        XCTAssertTrue(actions.contains("Edit workspace"))
    }

    func testTheWorkspaceMenusEditItemOpensTheEditor() throws {
        let id = model.currentWorkspace.id
        var edited: UUID?
        let menu = WorkspaceMenu.make(for: id, model: model, presentingView: NSView(), onEdit: { edited = $0 })
        let index = menu.indexOfItem(withTitle: "Edit…")
        XCTAssertEqual(index, 0, "C4: the menu leads with Edit…")
        menu.performActionForItem(at: index)
        XCTAssertEqual(edited, id)
    }

    func testTheEditorFromARailDotShowsEachChangeAsItsMade() throws {
        harness.host(width: 52)
        let id = model.currentWorkspace.id
        let editor = harness.controller.workspaceEditor
        let window = try XCTUnwrap(harness.window)
        editor.open(id, placement: {
            .init(anchor: NSRect(x: window.frame.minX, y: window.frame.maxY - 40, width: 20, height: 20),
                  edge: .beside(column: window.frame), parent: window)
        })
        defer { editor.close() }
        editor.editor.onIcon?(.letter)
        harness.spin()
        XCTAssertEqual(editor.editor.content?.icon, .letter, "the card shows the icon just picked, outside Settings too")
        editor.editor.onColor?(.ember)
        harness.spin()
        XCTAssertEqual(editor.editor.content?.colorId, .ember)
    }

    func testRightClickingARailDotShowsTheWorkspaceMenu() throws {
        harness.host(width: 52)
        let rail = try XCTUnwrap(harness.controller.view.descendants(of: RailView.self).first)
        XCTAssertNotNil(rail.onWorkspaceContextMenu, "C4: a dot's right-click opens the native WorkspaceMenu")
    }

    func testRightClickingTheTablineChipAsksForTheWorkspaceMenu() {
        let strip = TablineStripView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        var model = TablineStripModel()
        model.name = "Research"
        model.colorId = .ocean
        strip.update(model)
        var asked: TablineStripView.Kind?
        strip.onContextMenu = { kind, _ in asked = kind }
        let chip = strip.rect(of: .chip)!
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: chip.midX, y: chip.midY), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        strip.rightMouseDown(with: click)
        XCTAssertEqual(asked, .chip, "C4: the Tabline chip has a right-click")
    }

    func testMainWindowRoutesTheTablineChipMenu() {
        harness.host(width: 300)
        XCTAssertNotNil(TablineController.shared.onWorkspaceContextMenu, "C4: the Tabline routes its chip's right-click to WorkspaceMenu")
    }

    // MARK: G7 · one count

    func testActiveItemCountLeavesOutArchivedItemsAtEveryDepth() {
        let folder = Folder(id: UUID(), name: "Refs", children: [link("A"), link("B", archived: true)], isExpanded: true)
        let nodes: [Node] = [link("C"), link("D", archived: true), .folder(folder)]
        XCTAssertEqual(nodes.activeItemCount(), 2)
        XCTAssertEqual(nodes.leafCount(), 4)
    }

    func testTheRailTipCountsOnlyLiveItems() {
        let id = model.currentWorkspace.id
        let live = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        let archived = model.addLink(urlString: "https://b.com", title: "B", parentId: nil)
        model.archiveNode(id: archived)
        _ = live
        let controller = SettingsRailController(model: model)
        let detail = controller.detail(for: model.workspaces.first { $0.id == id }!, position: 1)
        XCTAssertTrue(detail.hasPrefix("1 item"), "G7: the tip counts the archived link too: \(detail)")
    }

    // MARK: X2 · narrow list

    func testTheOverflowChipStaysInsideANarrowStrip() {
        var items = ["Personal", "Engineering", "Side projects", "Reading"].map { WorkspaceStripLayout.Item(id: UUID(), name: $0) }
        WorkspaceStripLayout.assignMonograms(&items)
        let measure: (String, NSFont.Weight) -> CGFloat = { s, w in CGFloat(s.count) * (w == .semibold ? 7.5 : 7) }
        let metrics = WorkspaceStripLayout.metrics(for: items, measure: measure)
        for width: CGFloat in [72, 90, 104] {
            for page in 1...items.count {
                let l = WorkspaceStripLayout.rest(width: width, items: items, metrics: metrics, page: page, previous: nil)
                XCTAssertLessThanOrEqual(l.overflow.x + l.overflow.width, width + 0.5, "X2: the +N chip is cut at width \(width), page \(page)")
                XCTAssertLessThanOrEqual(l.used, width + 0.5)
            }
        }
    }

    func testTheFooterCollapsesToIconsInANarrowList() throws {
        harness.host(width: 150)
        let buttons = harness.controller.view.descendants(of: FooterButton.self)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertTrue(buttons.allSatisfy { $0.fit == .icon }, "X2: below ~180pt the footer keeps only its icons")
        XCTAssertEqual(Set(buttons.compactMap { $0.accessibilityLabel() }), ["+ Stow this tab", "Paste"], "VoiceOver keeps the names")
    }

    func testTheFooterCollapsesWhenTheWindowNarrowsAfterLaunch() throws {
        harness.host(width: 320)
        let buttons = harness.controller.view.descendants(of: FooterButton.self)
        XCTAssertTrue(buttons.allSatisfy { $0.fit != .icon })
        harness.window.setContentSize(NSSize(width: 150, height: 620))
        harness.window.contentView?.layoutSubtreeIfNeeded()
        harness.spin()
        XCTAssertTrue(buttons.allSatisfy { $0.fit == .icon }, "the fit follows the new width, not the footer's width before this layout pass")
    }

    func testTheFooterKeepsItsTitlesInASidebar() {
        harness.host(width: 320)
        let buttons = harness.controller.view.descendants(of: FooterButton.self)
        XCTAssertTrue(buttons.allSatisfy { $0.fit != .icon })
    }

    func testFooterFitPicksTheRoomiestThatFits() {
        XCTAssertEqual(FooterButton.footerFit(width: 300, stowFull: 150, stowTitle: 110, paste: 50), .full)
        XCTAssertEqual(FooterButton.footerFit(width: 184, stowFull: 150, stowTitle: 110, paste: 50), .noKeycap)
        XCTAssertEqual(FooterButton.footerFit(width: 150, stowFull: 150, stowTitle: 110, paste: 50), .icon)
    }

    func testTheSearchPlaceholderTruncatesWithAnEllipsis() throws {
        let bar = SearchBarView()
        bar.placeholder = "Search"
        let field = try XCTUnwrap(bar.descendants(of: NSTextField.self).first { $0.placeholderAttributedString != nil })
        let style = field.placeholderAttributedString?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.lineBreakMode, .byTruncatingTail, "X2: the placeholder is clipped to “Searcl” under the keycap")
    }

    func testTheMetaColumnClearsTheOverlayScroller() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scroll.documentView = document
        let row = NodeRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        document.addSubview(row)
        var metrics = ListMetrics()
        metrics.mode = .sidebar
        row.configure(content: NodeRowContent(kind: .link(favicon: nil, domain: "example.com"), title: "Example", depth: 0, isArchived: false),
                      metrics: metrics, isSelected: false, showSlotAction: false, onSlotAction: nil)
        row.layoutSubtreeIfNeeded()
        let meta = try XCTUnwrap(row.descendants(of: NSTextField.self).first { $0.stringValue == "example.com" })
        let maxX = meta.convert(meta.bounds, to: row).maxX
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        XCTAssertLessThanOrEqual(maxX, 300 - scroller + 0.5, "X2: the overlay scroller covers the meta column")
    }
}
