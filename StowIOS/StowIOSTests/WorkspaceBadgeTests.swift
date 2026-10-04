import XCTest
import StowShared
@testable import StowIOS

/// The iPhone draws each workspace the way the Mac's editor set it: favicons, letter
/// or symbol, including after the choice arrives from iCloud.
@MainActor
final class WorkspaceBadgeTests: XCTestCase {
    private var testStore: TestStore!
    private var icons: URL!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home"], selected: 0)
        icons = testStore.directory.appendingPathComponent("Icons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        testStore.remove()
    }

    private func link(_ host: String, macPath: Bool = false) -> Node {
        .link(StowShared.Link(id: UUID(), title: host, url: "https://\(host)/",
                              faviconPath: macPath ? "/Users/someone/Library/Application Support/Stow/Icons/\(host).ico" : nil))
    }

    func testTheModelReadsTheIconAfterASyncUpdate() {
        let model = AppModel(store: testStore.store)
        var remote = model.workspaces[0]
        XCTAssertNotEqual(WorkspaceBadge.identities(for: model.workspaces, iconsDirectory: icons)[remote.id], .symbol("book"))

        remote.icon = .symbol("book")
        model.updateWorkspaceFromSync(remote)

        XCTAssertEqual(WorkspaceBadge.identities(for: model.workspaces, iconsDirectory: icons)[remote.id], .symbol("book"))
    }

    func testLetterIconsUseTheSharedMonogram() {
        var work = Workspace(id: UUID(), name: "Work", colorId: .ocean, items: [], icon: .letter)
        let workshop = Workspace(id: UUID(), name: "Workshop", colorId: .moss, items: [], icon: .letter)
        work.icon = .letter
        let identities = WorkspaceBadge.identities(for: [work, workshop], iconsDirectory: icons)
        let expected = WorkspaceMonogram.assign([(work.id, work.name), (workshop.id, workshop.name)])
        XCTAssertEqual(identities[work.id], .letter(expected[work.id]!))
        XCTAssertEqual(identities[workshop.id], .letter(expected[workshop.id]!))
    }

    func testFaviconMosaicUsesTheIconsOnThisIPhone() throws {
        try Data([1]).write(to: icons.appendingPathComponent("linear.app.ico"))
        try Data([1]).write(to: icons.appendingPathComponent("figma.com.ico"))
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean,
                           items: [link("linear.app"), link("figma.com", macPath: true), link("notion.so", macPath: true)])

        guard case .mosaic(let links) = WorkspaceBadge.identities(for: [ws], iconsDirectory: icons)[ws.id] else {
            return XCTFail("expected a mosaic")
        }
        XCTAssertEqual(links.compactMap(\.displayDomain), ["linear.app", "figma.com"],
                       "notion.so's Mac path has no file here, so it's left out")
    }

    func testFaviconsWithNoIconsHereFallBackToTheLetter() {
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean, items: [link("notion.so", macPath: true)])
        XCTAssertEqual(WorkspaceBadge.identities(for: [ws], iconsDirectory: icons)[ws.id], .letter("R"))
    }

    // MARK: Live Activity

    func testLiveActivityCarriesASymbol() {
        let ws = Workspace(id: UUID(), name: "Home", colorId: .moss, items: [], icon: .symbol("house"))
        let state = LiveActivityController.state(for: ws, identity: .symbol("house"), iconsDirectory: icons)
        XCTAssertEqual(state.badgeSymbol, "house")
        XCTAssertNil(state.badgeIcons)
    }

    func testLiveActivityCarriesTheMosaicFileNames() throws {
        try Data([1]).write(to: icons.appendingPathComponent("linear.app.ico"))
        let site = StowShared.Link(id: UUID(), title: "Linear", url: "https://linear.app/", faviconPath: nil)
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean, items: [.link(site)])
        let state = LiveActivityController.state(for: ws, identity: .mosaic([site]), iconsDirectory: icons)
        XCTAssertEqual(state.badgeIcons, ["linear.app.ico"])
        XCTAssertNil(state.badgeSymbol)
    }

    func testLiveActivityLetterComesFromTheIdentity() {
        let ws = Workspace(id: UUID(), name: "Work", colorId: .ocean, items: [], icon: .letter)
        let state = LiveActivityController.state(for: ws, identity: .letter("Wo"), iconsDirectory: icons)
        XCTAssertEqual(state.monogram, "Wo")
        XCTAssertNil(state.badgeSymbol)
        XCTAssertNil(state.badgeIcons)
    }
}
