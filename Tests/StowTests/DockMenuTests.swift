import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Right-clicking the Dock icon lists the workspaces, the current one checked; choosing
/// one switches Stow to it without bringing the browser down.
@MainActor
final class DockMenuTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        _ = model.createWorkspace(name: "Personal")
        _ = model.createWorkspace(name: "Reading")
        model.selectWorkspace(id: model.workspaces[1].id)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func workspaceItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }
    }

    func testListsEveryWorkspaceWithTheCurrentOneChecked() {
        let menu = DockMenu.make(model: model, onSelect: { _ in })
        let items = workspaceItems(menu)
        XCTAssertEqual(items.map(\.title), model.workspaces.map(\.name))
        XCTAssertEqual(items.map(\.state), [.off, .on, .off])
    }

    func testChoosingAWorkspaceSelectsIt() {
        var chosen: UUID?
        let menu = DockMenu.make(model: model, onSelect: { chosen = $0 })
        let reading = workspaceItems(menu)[2]
        _ = reading.target?.perform(reading.action, with: reading)
        XCTAssertEqual(chosen, model.workspaces[2].id)
    }

    func testOnSettingsNoWorkspaceIsChecked() {
        model.selectSettings()
        let menu = DockMenu.make(model: model, onSelect: { _ in })
        XCTAssertTrue(workspaceItems(menu).allSatisfy { $0.state == .off })
    }
}
