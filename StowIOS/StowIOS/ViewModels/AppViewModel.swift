import SwiftUI
import UIKit
import StowShared

@MainActor
final class AppViewModel: ObservableObject {
    let model: AppModel
    @Published var refreshTrigger = false
    @Published var showingNewWorkspaceAlert = false
    @Published var newWorkspaceName = ""

    private static let appGroupID = "group.com.stow.app"

    init() {
        Self.migrateSyncStateIfNeeded()

        let baseDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stow")
        let store = DataStore(baseDirectory: baseDir)
        let model = AppModel(store: store)
        self.model = model
        model.onChange = { [weak self] in
            self?.refreshTrigger.toggle()
            CloudSyncManager.shared.scheduleLocalChanges()
        }

        // Initialize iCloud sync
        CloudSyncManager.shared.configure(model: model)
        CloudSyncManager.shared.fetchChanges()

        UIApplication.shared.registerForRemoteNotifications()
    }

    /// One-time migration: delete stale sync engine state from the old app sandbox location.
    /// After moving DataStore to the App Group container, the sync engine's cached state
    /// in Application Support still references the old data, causing it to think it's up to date.
    private static func migrateSyncStateIfNeeded() {
        let key = "syncStateMigratedToAppGroup_v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let syncDir = appSupport.appendingPathComponent("Stow/SyncEngine")
        try? FileManager.default.removeItem(at: syncDir)
        UserDefaults.standard.set(true, forKey: key)
    }

    var workspaces: [Workspace] {
        model.workspaces
    }

    var currentWorkspace: Workspace {
        model.currentWorkspace
    }

    var selectedWorkspaceId: UUID? {
        get { model.state.selectedWorkspaceId }
        set {
            if let id = newValue {
                model.selectWorkspace(id: id)
            }
        }
    }

    func selectWorkspace(id: UUID) {
        model.selectWorkspace(id: id)
    }

    func createWorkspace(name: String) {
        model.createWorkspace(name: name, colorId: .randomColor())
    }

    func deleteWorkspace(id: UUID) {
        model.deleteWorkspace(id: id)
    }
}
