import XCTest
@testable import StowShared

final class WorkspaceIconTests: XCTestCase {
    private func makeModel() -> AppModel {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(baseDirectory: temp)
        store.save(DataStore.defaultState())
        return AppModel(store: store)
    }

    func testNewWorkspacesShowTheirFavicons() {
        let ws = Workspace(id: UUID(), name: "A", colorId: .ocean, items: [])
        XCTAssertEqual(ws.icon, .favicons)
    }

    func testIconRoundTripsThroughJSON() throws {
        for icon in [WorkspaceIcon.favicons, .letter, .symbol("house")] {
            let ws = Workspace(id: UUID(), name: "A", colorId: .ocean, items: [], icon: icon)
            let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
            XCTAssertEqual(decoded.icon, icon)
        }
    }

    func testOlderDataWithoutAnIconDecodesAsFavicons() throws {
        let json = #"{"id":"7C3A2B8E-0F7B-4D53-9C3B-1F4C1C1E2A10","name":"Old","colorId":"ocean","items":[]}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(ws.icon, .favicons)
    }

    func testUpdatingTheIconPersists() {
        let model = makeModel()
        let id = model.currentWorkspace.id
        model.updateWorkspaceIcon(id: id, icon: .symbol("book"))
        XCTAssertEqual(model.workspaces.first?.icon, .symbol("book"))
    }
}
