import SwiftUI
import UIKit
import Combine
import StowShared

@MainActor
final class AppViewModel: ObservableObject {
    let model: AppModel
    @Published var showingNewWorkspaceAlert = false
    @Published var newWorkspaceName = ""
    @Published var searchQuery = ""
    // Save failures repeat on every mutation while the disk condition
    // persists; alert once per session and let os.log carry the rest.
    @Published var saveErrorMessage: String?
    private var hasReportedSaveError = false

    // Bulk-select state. The pager hosts NodeListView inside a UIHostingController,
    // which breaks SwiftUI's EditMode environment propagation — so the toolbar
    // (in WorkspacePageView) and the rows (deep inside the pager pages) coordinate
    // via these shared @Published fields instead.
    @Published var isSelecting: Bool = false
    @Published var selectedNodeIds: Set<UUID> = []

    func clearSelection() {
        isSelecting = false
        selectedNodeIds.removeAll()
    }

    private static let appGroupID = "group.com.stow.app"
    private var modelChangeSubscription: AnyCancellable?

    init() {
        Self.migrateSyncStateIfNeeded()

        let baseDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stow")
        let store = DataStore(baseDirectory: baseDir)
        var isSeededRun = false

        #if DEBUG
        // Seed the App Group container from a JSON fixture before AppModel loads.
        // Used by ios-simulator-skill scenarios to start each run from a known
        // state. Set STOW_SEED_FIXTURE=/path/to/fixture.json in the scheme env.
        if let fixturePath = ProcessInfo.processInfo.environment["STOW_SEED_FIXTURE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)) {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            try? data.write(to: baseDir.appendingPathComponent("data.json"))
            isSeededRun = true
        }
        #endif

        let model = AppModel(store: store)
        self.model = model

        // Forward every model change to SwiftUI's invalidation pipeline. Replaces
        // the old refreshTrigger.toggle() pattern — views no longer need to read
        // a sentinel @Published; reading any of viewModel's properties is enough.
        modelChangeSubscription = model.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
                CloudSyncManager.shared.scheduleLocalChanges()
                self?.refreshLiveActivity()
            }

        // Initialize iCloud sync. Fixture runs stay local so seed data never
        // reaches the signed-in iCloud account.
        if !isSeededRun {
            CloudSyncManager.shared.configure(model: model)
        }
        model.deletionScheduler = { ids in
            for id in ids { CloudSyncManager.shared.scheduleDeletion(for: id) }
        }
        model.onSaveError = { [weak self] error in
            guard let self, !self.hasReportedSaveError else { return }
            self.hasReportedSaveError = true
            self.saveErrorMessage = "Your latest changes are kept in memory but could not be written to disk: \(error.localizedDescription)"
        }
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

    /// Mirrors the current workspace into the Dynamic Island. Unchanged states are
    /// skipped unless `force` is set, which re-requests an expired or dismissed activity.
    func refreshLiveActivity(force: Bool = false) {
        LiveActivityController.shared.sync(workspace: model.currentWorkspace, force: force)
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
        model.createWorkspace(name: name)
    }

    func deleteWorkspace(id: UUID) {
        model.deleteWorkspace(id: id)
    }
}
