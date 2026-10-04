import XCTest
import CloudKit
@testable import StowShared

/// The workspace identity the Mac picks in its editor (favicons, letter or symbol) is
/// resolved in StowShared so the iPhone draws the same thing, and it reaches the iPhone
/// through CloudKit.
final class WorkspaceTileIdentitySharedTests: XCTestCase {

    private func link(_ host: String, favicon: Bool = true) -> Node {
        .link(Link(id: UUID(), title: host, url: "https://\(host)/", faviconPath: favicon ? "/mac/Icons/\(host).ico" : nil))
    }

    func testEachIconValueResolvesToItsIdentity() {
        let favicons = Workspace(id: UUID(), name: "Research", colorId: .ocean,
                                 items: ["linear.app", "figma.com", "notion.so", "arxiv.org", "vercel.com"].map { link($0) })
        let letter = Workspace(id: UUID(), name: "Reading", colorId: .graphite, items: [link("a.org")], icon: .letter)
        let symbol = Workspace(id: UUID(), name: "Personal", colorId: .ruby, items: [link("b.org")], icon: .symbol("house"))

        let identities = WorkspaceTileIdentity.resolve([favicons, letter, symbol])

        guard case .mosaic(let links) = identities[favicons.id] else { return XCTFail("expected a mosaic") }
        XCTAssertEqual(links.map(\.url), WorkspaceIconSites.pick(from: favicons.items).map(\.url))
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(identities[letter.id], .letter("R"))
        XCTAssertEqual(identities[symbol.id], .symbol("house"))
    }

    func testFaviconsWithNothingToShowFallBackToTheLetter() {
        let ws = Workspace(id: UUID(), name: "reading", colorId: .graphite, items: [link("x.org", favicon: false)])
        XCTAssertEqual(WorkspaceTileIdentity.resolve([ws])[ws.id], .letter("R"))
    }

    func testTheCallerDecidesWhichLinksHaveAnIcon() {
        // The iPhone checks its own icon folder: a path recorded on the Mac doesn't count,
        // and a link without a path whose icon is on disk does.
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean,
                           items: [link("linear.app"), link("figma.com", favicon: false)])
        let onDisk: Set<String> = ["figma.com"]
        let identities = WorkspaceTileIdentity.resolve([ws]) { onDisk.contains($0.displayDomain ?? "") }
        guard case .mosaic(let links) = identities[ws.id] else { return XCTFail("expected a mosaic") }
        XCTAssertEqual(links.map(\.displayDomain), ["figma.com"])
    }

    func testSymbolsMatchTheMacEditor() {
        XCTAssertEqual(WorkspaceTileIdentity.symbols,
                       ["house", "hammer", "book", "flask", "paperplane", "star", "music.note", "cart"])
    }

    // MARK: Sync delivers the icon

    private func makeModel() -> AppModel {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(baseDirectory: temp)
        store.save(DataStore.defaultState())
        return AppModel(store: store)
    }

    func testEveryIconRoundTripsThroughTheCloudKitRecord() {
        for icon in [WorkspaceIcon.favicons, .letter, .symbol("music.note")] {
            let ws = Workspace(id: UUID(), name: "Home", colorId: .moss, items: [], icon: icon)
            let record = RecordConverter.workspaceToCKRecord(workspace: ws, sortOrder: 0, zoneID: CKRecordZone.ID(zoneName: "TestZone"))
            XCTAssertEqual(RecordConverter.ckRecordToWorkspace(record: record)?.icon, icon)
        }
    }

    @MainActor
    func testASyncUpdateChangesTheResolvedIdentity() {
        let model = makeModel()
        var remote = model.currentWorkspace
        remote.icon = .symbol("star")
        model.updateWorkspaceFromSync(remote)
        XCTAssertEqual(WorkspaceTileIdentity.resolve(model.workspaces)[remote.id], .symbol("star"))
    }

    @MainActor
    func testANameMergeCarriesTheIcon() {
        let model = makeModel()
        let local = model.currentWorkspace
        let remote = Workspace(id: UUID(), name: local.name, colorId: local.colorId, items: [], icon: .letter)
        model.mergeWorkspaceMetadataFromSync(remote: remote, intoWorkspaceId: local.id)
        XCTAssertEqual(model.workspaces.first { $0.id == local.id }?.icon, .letter)
    }
}
