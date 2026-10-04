import XCTest
@testable import StowShared

/// Sharing a workspace: the link points at Stow's own share page, that page hands off
/// to the app with stow://import, and importing it recreates the workspace.
@MainActor
final class ShareLinkTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testShareLinksPointAtStowsOwnSharePage() throws {
        let model = AppModel(store: DataStore(baseDirectory: tempDir))
        let url = try model.shareWorkspace(id: model.currentWorkspace.id)
        XCTAssertTrue(url.hasPrefix("https://sryo.github.io/stow/web/share/#"), url)
    }

    func testSharedWorkspaceImportsWithItsLinksAndFolders() throws {
        let sender = AppModel(store: DataStore(baseDirectory: tempDir.appendingPathComponent("a")))
        let folder = sender.addFolder(name: "Refs", parentId: nil)
        _ = sender.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        _ = sender.addLink(urlString: "https://swift.org", title: "Swift", parentId: folder)
        let url = try sender.shareWorkspace(id: sender.currentWorkspace.id)

        let receiver = AppModel(store: DataStore(baseDirectory: tempDir.appendingPathComponent("b")))
        let fragment = try XCTUnwrap(ShareService.importFragment(from: URL(string: url)!))
        let id = try receiver.importWorkspaceFromShareURL(fragment: fragment)
        let imported = try XCTUnwrap(receiver.workspaces.first { $0.id == id })
        let links = imported.items.flattenLinks().map(\.url).sorted()
        XCTAssertEqual(links, ["https://example.com", "https://swift.org"])
        XCTAssertTrue(imported.items.contains { if case .folder(let f) = $0 { return f.name == "Refs" } else { return false } })
    }

    func testImportFragmentAcceptsAppAndPageLinksOnly() {
        XCTAssertEqual(ShareService.importFragment(from: URL(string: "stow://import#abc")!), "abc")
        XCTAssertEqual(ShareService.importFragment(from: URL(string: "https://sryo.github.io/stow/web/share/#abc")!), "abc")
        XCTAssertNil(ShareService.importFragment(from: URL(string: "arcmark://import#abc")!))
        XCTAssertNil(ShareService.importFragment(from: URL(string: "stow://import")!))
        XCTAssertNil(ShareService.importFragment(from: URL(string: "https://example.com/#abc")!))
    }

    /// The share page's "Open in Stow" button must use Stow's scheme, not the fork's.
    func testSharePageOpensStowNotArcmark() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/share/index.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("stow://import#"), "share page never hands off to Stow")
        XCTAssertFalse(html.contains("arcmark://"), "share page still opens Arcmark")
    }

    /// One entry point for every incoming link, used by the Mac app and the iPhone app.
    func testImportSharedLinkImportsShareLinksAndIgnoresOthers() throws {
        let sender = AppModel(store: DataStore(baseDirectory: tempDir.appendingPathComponent("a")))
        _ = sender.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        let page = URL(string: try sender.shareWorkspace(id: sender.currentWorkspace.id))!
        let appLink = URL(string: "stow://import#" + page.fragment!)!

        let receiver = AppModel(store: DataStore(baseDirectory: tempDir.appendingPathComponent("b")))
        let before = receiver.workspaces.count
        XCTAssertNotNil(try receiver.importSharedLink(appLink))
        XCTAssertEqual(receiver.workspaces.count, before + 1)
        XCTAssertNil(try receiver.importSharedLink(URL(string: "stow://open?url=https://example.com")!))
        XCTAssertEqual(receiver.workspaces.count, before + 1)
    }

    /// The app compresses with Apple's ZLIB (raw deflate, no header). Browsers only know
    /// that format as 'deflate-raw'; 'raw' throws, so no shared link would load.
    func testSharePageDecodesRawDeflate() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/share/index.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        XCTAssertTrue(html.contains("new DecompressionStream('deflate-raw')"), "share page can't decode the app's links")
    }
}
