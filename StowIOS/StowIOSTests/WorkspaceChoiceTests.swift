import XCTest
import StowShared
@testable import StowIOS

final class WorkspaceChoiceTests: XCTestCase {
    private let a = Workspace(id: UUID(), name: "Work", colorId: .ocean, items: [])
    private let b = Workspace(id: UUID(), name: "Home", colorId: .moss, items: [])

    func testCurrentFollowsTheOpenWorkspace() {
        XCTAssertEqual(WorkspaceChoice.current.resolve(workspaces: [a, b], currentId: b.id)?.id, b.id)
    }

    func testCurrentFallsBackToTheFirstWorkspace() {
        XCTAssertEqual(WorkspaceChoice.current.resolve(workspaces: [a, b], currentId: nil)?.id, a.id)
    }

    func testAPinnedWorkspaceIgnoresTheOpenOne() {
        XCTAssertEqual(WorkspaceChoice.workspace(a.id).resolve(workspaces: [a, b], currentId: b.id)?.id, a.id)
    }

    func testADeletedPinnedWorkspaceFallsBackToTheOpenOne() {
        XCTAssertEqual(WorkspaceChoice.workspace(UUID()).resolve(workspaces: [a, b], currentId: b.id)?.id, b.id)
    }

    func testNoWorkspacesResolvesToNil() {
        XCTAssertNil(WorkspaceChoice.current.resolve(workspaces: [], currentId: nil))
    }

    func testStorageRoundTrip() {
        XCTAssertEqual(WorkspaceChoice(storageValue: WorkspaceChoice.current.storageValue), .current)
        XCTAssertEqual(WorkspaceChoice(storageValue: WorkspaceChoice.workspace(a.id).storageValue), .workspace(a.id))
    }

    func testMissingOrGarbledStorageMeansCurrent() {
        XCTAssertEqual(WorkspaceChoice(storageValue: nil), .current)
        XCTAssertEqual(WorkspaceChoice(storageValue: "not-a-uuid"), .current)
    }

    func testResolvesFromAppState() {
        let state = AppState(schemaVersion: 2, workspaces: [a, b], selectedWorkspaceId: b.id, isSettingsSelected: false)
        XCTAssertEqual(WorkspaceChoice.current.resolve(in: state)?.id, b.id)
    }
}
