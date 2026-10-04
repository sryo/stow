import XCTest
import Carbon
@testable import StowCore

// MARK: - Main menu

@MainActor
final class AppMenusTests: XCTestCase {
    private func menu(_ title: String, in main: NSMenu) -> NSMenu? {
        main.items.first { $0.submenu?.title == title }?.submenu
    }

    func testWindowMenuHasAWindowModeSubmenuInsteadOfAlwaysOnTop() {
        let main = AppMenus.build(target: nil)
        guard let window = menu("Window", in: main) else { return XCTFail("no Window menu") }
        XCTAssertNil(window.item(withTitle: "Always on top"))
        guard let mode = window.item(withTitle: "Window Mode")?.submenu else { return XCTFail("no Window Mode submenu") }
        XCTAssertEqual(mode.items.map(\.title), ["Floating", "On Top", "Attached", "", "Switch On Top and Floating"])
        let toggle = mode.item(withTitle: "Switch On Top and Floating")!
        XCTAssertEqual(toggle.keyEquivalent, "t")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.command, .option])
    }

    func testShowTablineIsOptionCommandL() {
        let window = menu("Window", in: AppMenus.build(target: nil))!
        let tabline = window.item(withTitle: "Show Tabline")!
        XCTAssertEqual(tabline.keyEquivalent, "l")
        XCTAssertEqual(tabline.keyEquivalentModifierMask, [.command, .option])
    }

    func testNextAndPreviousWorkspaceUseControlTab() {
        let window = menu("Window", in: AppMenus.build(target: nil))!
        let next = window.item(withTitle: "Next Workspace")!
        let previous = window.item(withTitle: "Previous Workspace")!
        XCTAssertEqual(next.keyEquivalent, "\t")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(previous.keyEquivalent, "\t")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertNotNil(window.item(withTitle: "Workspace 1"))
    }

    func testFileMenuHasImportExportAllAndRestore() {
        let file = menu("File", in: AppMenus.build(target: nil))!
        let titles = file.items.map(\.title)
        for title in ["Import…", "Export All…", "Restore from Backup…"] {
            XCTAssertTrue(titles.contains(title), "\(title) in \(titles)")
        }
        // ⌥ turns Export All into Show Data in Finder.
        let showData = file.item(withTitle: "Show Data in Finder")!
        XCTAssertTrue(showData.isAlternate)
        XCTAssertEqual(showData.keyEquivalentModifierMask, file.item(withTitle: "Export All…")!.keyEquivalentModifierMask.union(.option))
    }

    func testWorkspaceSteppingWraps() {
        XCTAssertEqual(AppMenus.steppedIndex(current: 0, count: 3, step: 1), 1)
        XCTAssertEqual(AppMenus.steppedIndex(current: 2, count: 3, step: 1), 0)
        XCTAssertEqual(AppMenus.steppedIndex(current: 0, count: 3, step: -1), 2)
        XCTAssertEqual(AppMenus.steppedIndex(current: nil, count: 3, step: 1), 0, "from Settings, the first workspace")
        XCTAssertNil(AppMenus.steppedIndex(current: nil, count: 0, step: 1))
    }
}

// MARK: - Workspace menu

@MainActor
final class WorkspaceMenuTests: XCTestCase {
    func testOneMenuWithThePlansItems() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: DataStore(baseDirectory: dir))
        _ = model.createWorkspace(name: "Second", colorId: .ocean)
        let menu = WorkspaceMenu.make(for: model.workspaces[0].id, model: model, presentingView: NSView(), onRename: { _ in })
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Rename", "Color", "Icon", "Opens in", "Move Up", "Move Down", "Share…", "Export…", "Delete"])
        XCTAssertFalse(menu.item(withTitle: "Move Up")!.isEnabled)
        XCTAssertNotNil(menu.item(withTitle: "Icon")?.submenu?.item(withTitle: "Favicons"))
        XCTAssertNotNil(menu.item(withTitle: "Opens in")?.submenu?.item(withTitle: OpensIn.browserImUsing))
    }
}

// MARK: - Import parsers

final class BookmarkParserTests: XCTestCase {
    func testChromeBookmarksBecomeOneWorkspacePerRoot() throws {
        let json = """
        {"roots": {
          "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
             {"type": "url", "name": "Linear", "url": "https://linear.app/"},
             {"type": "folder", "name": "Docs", "children": [{"type": "url", "name": "MDN", "url": "https://developer.mozilla.org/"}]}
          ]},
          "other": {"name": "Other bookmarks", "type": "folder", "children": []},
          "synced": {"name": "Mobile bookmarks", "type": "folder", "children": [{"type": "url", "name": "News", "url": "https://news.ycombinator.com/"}]}
        }}
        """
        let workspaces = try BookmarkParsers.chrome(Data(json.utf8), browserName: "Chrome")
        XCTAssertEqual(workspaces.map(\.name), ["Chrome · Bookmarks bar", "Chrome · Mobile bookmarks"], "empty roots are skipped")
        let bar = workspaces[0].nodes
        XCTAssertEqual(bar.count, 2)
        guard case .link(let linear) = bar[0], case .folder(let docs) = bar[1] else { return XCTFail() }
        XCTAssertEqual(linear.url, "https://linear.app/")
        XCTAssertEqual(docs.name, "Docs")
        XCTAssertEqual(docs.children.count, 1)
    }

    func testNetscapeHTMLKeepsFolders() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
          <DT><H3>Reading</H3>
          <DL><p>
            <DT><A HREF="https://example.com/a" ADD_DATE="1">Article &amp; notes</A>
          </DL><p>
          <DT><A HREF="https://example.com/b">Top level</A>
        </DL><p>
        """
        let workspaces = BookmarkParsers.netscapeHTML(html, name: "Bookmarks")
        XCTAssertEqual(workspaces.count, 1)
        let nodes = workspaces[0].nodes
        guard case .folder(let reading) = nodes[0], case .link(let top) = nodes[1] else { return XCTFail("\(nodes)") }
        XCTAssertEqual(reading.name, "Reading")
        guard case .link(let article) = reading.children.first else { return XCTFail() }
        XCTAssertEqual(article.title, "Article & notes")
        XCTAssertEqual(top.url, "https://example.com/b")
    }

    func testSafariPlistSkipsReadingListAndHistory() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com/", "URIDictionary": ["title": "Apple"]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.com/", "URIDictionary": ["title": "Later"]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let workspaces = try BookmarkParsers.safari(data)
        XCTAssertEqual(workspaces.map(\.name), ["Safari · Favorites"])
        guard case .link(let apple) = workspaces[0].nodes.first else { return XCTFail() }
        XCTAssertEqual(apple.title, "Apple")
    }

    func testDroppedFilesAreRecognizedByKind() {
        XCTAssertEqual(ImportSource.forFile(URL(fileURLWithPath: "/x/Research.stow")), .stowFile)
        XCTAssertEqual(ImportSource.forFile(URL(fileURLWithPath: "/x/bookmarks.html")), .htmlFile)
        XCTAssertEqual(ImportSource.forFile(URL(fileURLWithPath: "/x/Stow export.json")), .stowBackup)
        XCTAssertNil(ImportSource.forFile(URL(fileURLWithPath: "/x/photo.png")))
    }
}

// MARK: - Export All and backups

final class ExportAndBackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleState() -> AppState {
        let folder = Folder(id: UUID(), name: "Docs & refs", children: [.link(Link(id: UUID(), title: "MDN", url: "https://developer.mozilla.org/", faviconPath: nil))], isExpanded: true)
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean, items: [
            .link(Link(id: UUID(), title: "Linear <app>", url: "https://linear.app/", faviconPath: nil)), .folder(folder),
        ])
        return AppState(schemaVersion: DataStore.currentSchemaVersion, workspaces: [ws], selectedWorkspaceId: ws.id, isSettingsSelected: false)
    }

    func testExportAllJSONRestoresTheWholeLibrary() throws {
        let state = sampleState()
        let data = try LibraryExport.json(state)
        let restored = try LibraryExport.state(fromBackup: data)
        XCTAssertEqual(restored.workspaces.map(\.id), state.workspaces.map(\.id))
        XCTAssertEqual(restored.workspaces[0].items, state.workspaces[0].items)
    }

    func testExportAllHTMLIsANetscapeBookmarksFileBrowsersImport() throws {
        let html = LibraryExport.html(sampleState())
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(html.contains("<DT><H3>Research</H3>"))
        XCTAssertTrue(html.contains("<DT><A HREF=\"https://linear.app/\">Linear &lt;app&gt;</A>"))
        XCTAssertTrue(html.contains("<DT><H3>Docs &amp; refs</H3>"))
        // And Stow reads its own export back.
        let reimported = BookmarkParsers.netscapeHTML(html, name: "Export")
        XCTAssertFalse(reimported.isEmpty)
    }

    func testOneBackupPerDayKeepingFourteen() throws {
        let backups = BackupService(baseDirectory: dir)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("data.json"))
        let day: TimeInterval = 86400
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<20 {
            backups.backUpIfNeeded(now: start.addingTimeInterval(Double(i) * day))
            backups.backUpIfNeeded(now: start.addingTimeInterval(Double(i) * day + 3600)) // same day: no second copy
        }
        let list = backups.list()
        XCTAssertEqual(list.count, 14)
        XCTAssertEqual(list.first?.date, start.addingTimeInterval(19 * day), "newest first")
        XCTAssertTrue(list.allSatisfy { $0.url.deletingLastPathComponent().lastPathComponent == "Backups" })
    }

    func testRestoringABackupReplacesDataAndKeepsASnapshotOfTheCurrentOne() throws {
        let backups = BackupService(baseDirectory: dir)
        let dataURL = dir.appendingPathComponent("data.json")
        try Data("old".utf8).write(to: dataURL)
        backups.backUpIfNeeded(now: Date(timeIntervalSince1970: 1_800_000_000))
        try Data("new".utf8).write(to: dataURL)
        let snapshot = backups.list()[0]
        try backups.restore(snapshot, now: Date(timeIntervalSince1970: 1_800_100_000))
        XCTAssertEqual(try String(contentsOf: dataURL, encoding: .utf8), "old")
        XCTAssertTrue(backups.list().contains { (try? String(contentsOf: $0.url, encoding: .utf8)) == "new" },
                      "the data being replaced is kept as a backup too")
    }
}
