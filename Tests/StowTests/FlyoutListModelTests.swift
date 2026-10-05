import XCTest
@testable import StowCore
import StowShared

/// The rows every list flyout draws (rail folder, tasks and snippets cells; Tabline group,
/// overflow, pocket and chip; the tab strip's "+N"), built from one pure model so the
/// rail and the Tabline can't drift apart again.
@MainActor
final class FlyoutListModelTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))! }

    private func link(_ title: String, _ url: String, archived: Bool = false) -> Link {
        Link(id: UUID(), title: title, url: url, faviconPath: nil, isArchived: archived)
    }

    private func task(_ title: String, done: Bool = false, due: Date? = nil) -> TaskItem {
        TaskItem(id: UUID(), title: title, isCompleted: done, dueDate: due, notes: nil, createdAt: now)
    }

    // MARK: Folder

    func testFolderRowsListLinksAndNestedFoldersButNotArchivedOnes() {
        let hig = link("Apple HIG", "https://developer.apple.com/design/")
        let gone = link("Old", "https://old.example", archived: true)
        let a = link("A", "https://a.example"), b = link("B", "https://b.example")
        let type = Folder(id: UUID(), name: "Type", children: [.link(a), .link(b)], isExpanded: false)
        let t = task("Reply")
        let folder = Folder(id: UUID(), name: "Design refs", children: [.link(hig), .link(gone), .folder(type), .task(t)], isExpanded: true)

        let rows = FlyoutListModel.rows(for: folder, openKeys: [])
        XCTAssertEqual(rows.map(\.title), ["Apple HIG", "Type"])
        XCTAssertEqual(rows[0].action, .openLink(hig.id))
        XCTAssertEqual(rows[0].node, .link(hig))
        XCTAssertFalse(rows[0].keepsOpen)
        XCTAssertEqual(rows[1].action, .pushFolder(type.id))
        XCTAssertEqual(rows[1].glyph, .folder)
        XCTAssertEqual(rows[1].trailing, "2 ›")
        XCTAssertTrue(rows[1].keepsOpen)
    }

    func testFolderRowsMarkOnlyTheExactOpenPage() {
        let profile = link("Profile", "https://github.com/sryo")
        let issues = link("Issues", "https://github.com/sryo/stow/issues")
        let folder = Folder(id: UUID(), name: "GitHub", children: [.link(profile), .link(issues)], isExpanded: true)
        let rows = FlyoutListModel.rows(for: folder, openKeys: [URLCanonical.key("https://github.com/sryo")!])
        XCTAssertEqual(rows.map(\.isOpen), [true, false])
    }

    func testAFolderOfOnlyArchivedItemsCountsZero() {
        let inner = Folder(id: UUID(), name: "Inner", children: [.link(link("x", "https://x.example", archived: true))], isExpanded: false)
        let folder = Folder(id: UUID(), name: "Outer", children: [.folder(inner)], isExpanded: false)
        XCTAssertEqual(FlyoutListModel.rows(for: folder, openKeys: []).first?.trailing, "0 ›")
    }

    // MARK: Tasks

    func testTaskRowsToggleInPlaceShowDueDatesAndEndWithNewTask() {
        let overdue = task("Review", due: calendar.date(byAdding: .day, value: -4, to: now))
        let soon = task("Send notes", due: calendar.date(byAdding: .day, value: 1, to: now))
        let done = task("Book flights", done: true)
        let rows = FlyoutListModel.rows(for: [overdue, soon, done], now: now, calendar: calendar)

        XCTAssertEqual(rows.map(\.title), ["Review", "Send notes", "Book flights", "New task"])
        XCTAssertEqual(rows[0].action, .toggleTask(overdue.id))
        XCTAssertTrue(rows[0].keepsOpen)
        XCTAssertTrue(rows[0].isOverdue)
        XCTAssertTrue(rows[0].trailing?.hasPrefix("! ") == true)
        XCTAssertFalse(rows[1].isOverdue)
        XCTAssertNotNil(rows[1].trailing)
        XCTAssertEqual(rows[1].secondary, .setDueDate(soon.id))
        XCTAssertTrue(rows[2].isChecked)
        XCTAssertEqual(rows[2].trailing, "done")
        XCTAssertEqual(rows[2].glyph, .task(done: true))
        XCTAssertEqual(rows[3].action, .newTask)
        XCTAssertFalse(rows[3].keepsOpen)
        XCTAssertNil(rows[3].node)
    }

    func testTaskRowsWithoutNewTaskForTheTabline() {
        let rows = FlyoutListModel.rows(for: [task("One")], newTask: false, now: now, calendar: calendar)
        XCTAssertEqual(rows.map(\.title), ["One"])
    }

    // MARK: Snippets

    func testSnippetRowsCopyKeepTheFlyoutOpenAndOfferEdit() {
        let s = Snippet(id: UUID(), title: "curl", content: "curl -s", language: "Shell", createdAt: now)
        let rows = FlyoutListModel.rows(for: [s])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].action, .copySnippet(s.id))
        XCTAssertEqual(rows[0].secondary, .editSnippet(s.id))
        XCTAssertEqual(rows[0].hoverTrailing, "Edit")
        XCTAssertEqual(rows[0].trailing, "Shell")
        XCTAssertTrue(rows[0].keepsOpen)
        XCTAssertFalse(rows[0].isChecked)
        XCTAssertEqual(rows[0].node, .snippet(s))
    }

    // MARK: Nodes (Tabline overflow)

    func testNodeRowsTurnGroupsIntoPushesAndSkipThePocket() {
        let a = link("A", "https://a.example")
        let group = Folder(id: UUID(), name: "Group", children: [.link(a)], isExpanded: true)
        let rows = FlyoutListModel.rows(for: [.link(a), .folder(group), .task(task("t"))], openKeys: [URLCanonical.key(a.url)!])
        XCTAssertEqual(rows.map(\.title), ["A", "Group"])
        XCTAssertTrue(rows[0].isOpen)
        XCTAssertEqual(rows[1].action, .pushFolder(group.id))
    }

    // MARK: Workspaces

    /// Each row shows the workspace's own tile (favicons, letter or symbol, as set in the
    /// editor) on its color, not a bare dot.
    func testWorkspaceRowsShowTheTileColorShortcutAndCurrent() {
        let one = UUID(), two = UUID()
        let rows = FlyoutListModel.rows(
            forWorkspaces: [(one, "Alpha", .defaultColor(), .letter("A")),
                            (two, "Beta", WorkspaceColorId.allCases[2], .symbol("book"))],
            current: two, shortcut: { "⌘\($0)" })
        XCTAssertEqual(rows.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(rows.map(\.trailing), ["⌘1", "⌘2"])
        XCTAssertEqual(rows.map(\.isChecked), [false, true])
        XCTAssertEqual(rows[1].glyph, .workspace(WorkspaceColorId.allCases[2], .symbol("book")))
        XCTAssertEqual(rows[0].glyph, .workspace(.defaultColor(), .letter("A")))
        XCTAssertEqual(rows[0].action, .selectWorkspace(one))
    }
}

/// The flyout card's background, for rendering a list on its own.
private final class RenderHolder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        FlyoutColors.background.setFill()
        bounds.fill()
    }
}

/// The list flyout itself, and the rail cells that open it in place of NSMenus.
@MainActor
final class FlyoutListViewTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.childWindows?.forEach { $0.orderOut(nil) }; $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func task(_ title: String, done: Bool = false) -> TaskItem {
        TaskItem(id: UUID(), title: title, isCompleted: done, dueDate: nil, notes: nil, createdAt: Date())
    }

    private func hostedRail(items: [Node]) -> RailView {
        let rail = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 52, height: 620), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rail
        window.orderFront(nil)
        windows.append(window)
        rail.configure(workspaces: [RailView.WorkspaceEntry(id: UUID(), name: "Alpha", colorId: .ocean)],
                       selectedId: nil, colorId: .defaultColor(), items: items)
        return rail
    }

    private func cell(_ rail: RailView, where match: (RailCell.Kind) -> Bool) -> RailCell? {
        rail.descendants(of: RailCell.self).first { match($0.kind) }
    }

    func testTheTasksCellOpensAFlyoutListNotAMenu() {
        let reply = task("Reply")
        let folder = Folder(id: UUID(), name: "Inbox", children: [.task(reply)], isExpanded: true)
        let rail = hostedRail(items: [.folder(folder)])
        var toggled: [UUID] = []
        rail.onToggleTask = { toggled.append($0) }
        guard let tasks = cell(rail, where: { if case .tasks = $0 { return true }; return false }) else {
            return XCTFail("no tasks cell for a task filed in a folder")
        }
        _ = tasks.accessibilityPerformPress()
        XCTAssertTrue(rail.flyout.isOpen)
        XCTAssertEqual(rail.flyout.rootList?.rows.map(\.title), ["Reply", "New task"])

        let row = rail.flyout.rootList!.rowViews[0]
        _ = row.accessibilityPerformPress()
        XCTAssertEqual(toggled, [reply.id])
        XCTAssertTrue(rail.flyout.isOpen, "toggling a task keeps the list open")
        XCTAssertTrue(rail.flyout.rootList?.rows[0].isChecked == true, "the row checks in place")

        _ = tasks.accessibilityPerformPress()
        XCTAssertFalse(rail.flyout.isOpen, "pressing the cell again closes its list")
    }

    func testNewTaskRowCallsOnNewTaskAndCloses() {
        let rail = hostedRail(items: [.task(task("One"))])
        var asked = 0
        rail.onNewTask = { asked += 1 }
        _ = cell(rail, where: { if case .tasks = $0 { return true }; return false })?.accessibilityPerformPress()
        _ = rail.flyout.rootList?.rowViews.last?.accessibilityPerformPress()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(rail.flyout.isOpen)
    }

    func testSnippetCopyShowsACheckAndRightClickReachesTheNodeMenu() {
        let s = Snippet(id: UUID(), title: "curl", content: "curl -s", language: nil, createdAt: Date())
        let rail = hostedRail(items: [.snippet(s)])
        var copied: [UUID] = []
        var menuNode: Node?
        rail.onCopySnippet = { copied.append($0) }
        rail.onNodeMenu = { node, _ in menuNode = node }
        _ = cell(rail, where: { if case .snippets = $0 { return true }; return false })?.accessibilityPerformPress()
        guard let row = rail.flyout.rootList?.rowViews.first else { return XCTFail("snippets list didn't open") }
        _ = row.accessibilityPerformPress()
        XCTAssertEqual(copied, [s.id])
        XCTAssertTrue(row.row.isChecked)
        XCTAssertTrue(rail.flyout.isOpen)
        _ = row.accessibilityPerformShowMenu()
        XCTAssertEqual(menuNode, .snippet(s))
    }

    func testTheFolderListHasOpenAllInItsFooterAndPushesSubfolders() {
        let a = Link(id: UUID(), title: "A", url: "https://a.example", faviconPath: nil)
        let b = Link(id: UUID(), title: "B", url: "https://b.example", faviconPath: nil)
        let sub = Folder(id: UUID(), name: "Sub", children: [.link(b)], isExpanded: false)
        let folder = Folder(id: UUID(), name: "Refs", children: [.link(a), .folder(sub)], isExpanded: true)
        let rail = hostedRail(items: [.folder(folder)])
        var openedAll: [UUID] = []
        rail.onOpenFolder = { openedAll.append($0.id) }
        _ = cell(rail, where: { if case .folder = $0 { return true }; return false })?.accessibilityPerformPress()
        guard let list = rail.flyout.rootList else { return XCTFail("folder list didn't open") }
        XCTAssertEqual(list.rows.map(\.title), ["A", "Sub"])

        _ = list.rowViews[1].accessibilityPerformPress()
        XCTAssertEqual(rail.flyout.panels.count, 2, "a nested folder pushes a chained flyout")
        XCTAssertEqual((rail.flyout.panels.last?.content as? FlyoutListView)?.rows.map(\.title), ["B"])

        list.performFooterAction(at: 0)
        XCTAssertEqual(openedAll, [folder.id])
        XCTAssertFalse(rail.flyout.isOpen)
    }

    func testAOneSiteFolderStillReadsAsAFolder() {
        let a = Link(id: UUID(), title: "A", url: "https://a.example", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Solo", children: [.link(a)], isExpanded: true)
        let cell = RailCell(kind: .folder(folder))
        let tiles = cell.layer?.sublayers?.filter { !$0.isHidden && $0.frame.width < 30 && $0.backgroundColor != nil } ?? []
        XCTAssertTrue(tiles.contains { $0.frame.width >= 16 }, "a one-link folder drew only ~11pt tiles: \(tiles.map(\.frame))")
    }

    // MARK: Keys

    func testArrowsAndReturnPickTheSelectedRow() {
        let rows = (1...3).map { FlyoutListRow(id: "\($0)", glyph: .snippet, title: "Row \($0)", action: .copySnippet(UUID())) }
        let list = FlyoutListView(title: "T", rows: rows)
        var picked: [String] = []
        list.onActivate = { row, _ in picked.append(row.id) }
        list.moveDown(nil)
        list.moveDown(nil)
        list.insertNewline(nil)
        list.moveUp(nil)
        list.insertNewline(nil)
        XCTAssertEqual(picked, ["2", "1"])
    }

    func testTypeSelectFindsATitleFromTheSelectionOnward() {
        let titles = ["Apple", "Figma", "Fonts", "GitHub"]
        XCTAssertEqual(FlyoutListView.typeSelectIndex("f", in: titles, from: nil), 1)
        XCTAssertEqual(FlyoutListView.typeSelectIndex("f", in: titles, from: 2), 2)
        XCTAssertEqual(FlyoutListView.typeSelectIndex("a", in: titles, from: 3), 0)
        XCTAssertEqual(FlyoutListView.typeSelectIndex("fo", in: titles, from: nil), 2)
        XCTAssertNil(FlyoutListView.typeSelectIndex("z", in: titles, from: nil))
    }

    // MARK: Tabline

    func testTheTablinePocketShowsTasksThenSnippetsWithoutEditorButtons() {
        let s = Snippet(id: UUID(), title: "curl", content: "c", language: nil, createdAt: Date())
        let pocket = Pocket.Contents(tasks: [task("One")], snippets: [s])
        let sections = TablineController.pocketSections(pocket)
        XCTAssertEqual(sections.map(\.title), [nil, "Snippets"])
        XCTAssertEqual(sections[0].rows.map(\.title), ["One"], "no New task in the Tabline")
        XCTAssertTrue(sections.flatMap(\.rows).allSatisfy { $0.secondary == nil && $0.hoverTrailing == nil })
    }

    func testRenderForComparison() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLYOUT_RENDER_DIR"] else { throw XCTSkip("FLYOUT_RENDER_DIR not set") }
        let hig = Link(id: UUID(), title: "Apple HIG · Sidebars", url: "https://developer.apple.com/design/", faviconPath: nil)
        let figma = Link(id: UUID(), title: "Figma community", url: "https://figma.com/community", faviconPath: nil)
        let type = Folder(id: UUID(), name: "Type", children: [.link(hig), .link(figma)], isExpanded: false)
        let folder = Folder(id: UUID(), name: "Design refs", children: [.link(hig), .link(figma), .folder(type)], isExpanded: true)
        let overdue = TaskItem(id: UUID(), title: "Review launch checklist", isCompleted: false,
                               dueDate: Date().addingTimeInterval(-4 * 86_400), notes: nil, createdAt: Date())
        let lists: [(String, FlyoutListView)] = [
            ("folder", FlyoutListView(title: folder.name, detail: "3",
                                      rows: FlyoutListModel.rows(for: folder, openKeys: [URLCanonical.key(hig.url)!]),
                                      footer: [.init(title: "Open all  ⌥↩", style: .primary) {}])),
            ("tasks", FlyoutListView(title: "Tasks", detail: "2 open",
                                     rows: FlyoutListModel.rows(for: [overdue, task("Send design notes"), task("Book flights", done: true)]))),
            ("workspaces", FlyoutListView(title: "Workspaces", rows: FlyoutListModel.rows(
                forWorkspaces: [(UUID(), "Research", .defaultColor(), .letter("R")), (UUID(), "Home", WorkspaceColorId.allCases[4], .symbol("house"))],
                current: nil, shortcut: { "⌘\($0)" }))),
        ]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (kind, list) in lists {
                let size = list.preferredSize
                let holder = RenderHolder(frame: NSRect(origin: .zero, size: size))
                holder.appearance = NSAppearance(named: appearance)
                list.frame = holder.bounds
                holder.addSubview(list)
                list.layoutSubtreeIfNeeded()
                list.rowViews.first?.isSelected = kind == "folder"
                let rep = holder.bitmapImageRepForCachingDisplay(in: holder.bounds)!
                holder.cacheDisplay(in: holder.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("flyout_\(kind)_\(name).png"))
            }
        }
    }

    // MARK: Dots

    func testWorkspaceDotRingsSitOutsideTheDot() {
        let dot = NSRect(x: 10, y: 10, width: 12, height: 12)
        let rings = WorkspaceDot.rings(around: dot)
        XCTAssertEqual(rings.ring, dot.insetBy(dx: -3.5, dy: -3.5))
        XCTAssertEqual(rings.gap, dot.insetBy(dx: -2, dy: -2))
        XCTAssertEqual(WorkspaceDot.image(color: .red, diameter: 10).size, NSSize(width: 10, height: 10))
    }
}
