import AppKit
import XCTest
@testable import StowCore
import StowShared

/// "Open all" opens the links the folder shows: archived links (and everything in an
/// archived subfolder) stay closed, whichever surface it's run from.
@MainActor
final class OpenAllTests: XCTestCase {
    private func link(_ title: String, archived: Bool = false) -> Link {
        Link(id: UUID(), title: title, url: "https://\(title.lowercased()).example", faviconPath: nil, isArchived: archived)
    }

    /// Live: A, C. Archived: B, D, and E inside an archived folder.
    private lazy var folder: Folder = {
        let inner = Folder(id: UUID(), name: "Inner", children: [.link(link("C")), .link(link("D", archived: true))], isExpanded: true)
        let gone = Folder(id: UUID(), name: "Gone", children: [.link(link("E"))], isExpanded: true, isArchived: true)
        return Folder(id: UUID(), name: "Refs", children: [.link(link("A")), .link(link("B", archived: true)), .folder(inner), .folder(gone)],
                      isExpanded: true)
    }()

    func testTheSharedHelperSkipsArchivedLinksAtEveryDepth() {
        XCTAssertEqual(folder.openableLinks.map(\.title), ["A", "C"])
        XCTAssertEqual([Node.folder(folder)].openableLinks().map(\.title), ["A", "C"])
    }

    func testOnlyArchivedLinksLeaveNothingToOpen() {
        let folder = Folder(id: UUID(), name: "Old", children: [.link(link("B", archived: true))], isExpanded: true)
        XCTAssertTrue(folder.openableLinks.isEmpty)
    }

    /// The rail flyout, the list's ⌥↩ and its "Open all links" menu item all go here.
    func testLinkActionsOpenAllSkipsArchivedLinks() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-openall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let links = LinkActions(model: AppModel(store: DataStore(baseDirectory: dir)), window: { nil })
        var opened: [String] = []
        links.openMany = { opened.append(contentsOf: $0.map(\.title)) }
        links.openLinksInFolder(folder)
        XCTAssertEqual(opened, ["A", "C"])
    }

    func testTablineOpenAllSkipsArchivedLinks() {
        let tabline = TablineController.shared
        let savedFolder = tabline.onOpenFolder, savedLink = tabline.onOpenLink
        defer { tabline.onOpenFolder = savedFolder; tabline.onOpenLink = savedLink }
        var opened: [String] = []
        tabline.onOpenFolder = nil
        tabline.onOpenLink = { opened.append($0.title) }
        tabline.openAll(folder)
        XCTAssertEqual(opened, ["A", "C"])
    }

    func testTheOpenAllButtonOnlyShowsWhenThereIsSomethingToOpen() {
        let archivedOnly = Folder(id: UUID(), name: "Old", children: [.link(link("B", archived: true))], isExpanded: true)
        var actions = NodeMenu.Actions()
        actions.openFolder = { _ in }
        let menu = NodeMenu.make(for: .folder(archivedOnly), model: AppModel(store: DataStore(baseDirectory:
            FileManager.default.temporaryDirectory.appendingPathComponent("stow-openall-menu-\(UUID().uuidString)"))), actions: actions)
        XCTAssertNil(menu.items.first { $0.title == "Open all links" }, "offered to open a folder of archived links")
    }
}
