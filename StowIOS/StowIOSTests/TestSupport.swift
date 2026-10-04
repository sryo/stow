import Foundation
import StowShared

/// A data.json in a throwaway folder with named workspaces, so tests never touch the
/// App Group container the host app is using.
struct TestStore {
    let directory: URL
    let store: DataStore
    let workspaceIds: [UUID]

    init(workspaces names: [String] = ["Work", "Home", "Reading"], selected: Int? = 0) {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-ios-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DataStore(baseDirectory: directory)
        let workspaces = names.enumerated().map { index, name in
            Workspace(id: UUID(), name: name, colorId: WorkspaceColorId.allCases[index % WorkspaceColorId.allCases.count], items: [])
        }
        workspaceIds = workspaces.map(\.id)
        store.save(AppState(
            schemaVersion: DataStore.currentSchemaVersion,
            workspaces: workspaces,
            selectedWorkspaceId: selected.map { workspaces[$0].id },
            isSettingsSelected: false
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A private defaults domain per test.
final class TestDefaults {
    let name = "stow-ios-tests-\(UUID().uuidString)"
    lazy var defaults: UserDefaults = UserDefaults(suiteName: name)!

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

extension AppModel {
    func link(_ id: UUID) -> (workspace: Workspace, link: StowShared.Link)? {
        for workspace in workspaces {
            for link in workspace.items.flattenLinks() where link.id == id {
                return (workspace, link)
            }
        }
        return nil
    }
}
