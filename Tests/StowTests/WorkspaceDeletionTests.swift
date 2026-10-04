import XCTest
@testable import StowCore

@MainActor
final class WorkspaceDeletionTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUp() async throws {
        do {
            tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-delete-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            model = AppModel(store: DataStore(baseDirectory: tempDir))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDeleteHappensAtOnceWithoutAConfirmation() {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        let pending = WorkspaceDeletion.deleteUndoably(id, model: model)
        XCTAssertNotNil(pending)
        XCTAssertFalse(model.workspaces.contains { $0.id == id })
        XCTAssertEqual(pending?.message, "Deleted “Research”")
    }

    func testUndoBringsItBack() {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        _ = model.createWorkspace(name: "Home", colorId: .ruby)
        let index = model.workspaces.firstIndex { $0.id == id }!
        let pending = WorkspaceDeletion.deleteUndoably(id, model: model)
        pending?.undo()
        XCTAssertEqual(model.workspaces.firstIndex { $0.id == id }, index)
        pending?.undo()
        XCTAssertEqual(model.workspaces.filter { $0.id == id }.count, 1)
    }

    func testTheOnlyWorkspaceCantBeDeleted() {
        XCTAssertNil(WorkspaceDeletion.deleteUndoably(model.workspaces[0].id, model: model))
        XCTAssertEqual(model.workspaces.count, 1)
    }

    func testAfterTheToastExpiresUndoDoesNothing() {
        let id = model.createWorkspace(name: "Research", colorId: .ocean)
        let pending = WorkspaceDeletion.deleteUndoably(id, model: model)
        pending?.expire()
        pending?.undo()
        XCTAssertFalse(model.workspaces.contains { $0.id == id })
    }
}
