import SwiftUI
import UIKit
import Combine
import WidgetKit
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

    /// Dynamic Island & Lock Screen, and which workspace it shows.
    let liveActivitySettings = LiveActivitySettings()
    private let pageColorStore: PageColorStore
    private let shareInbox: ShareInbox
    private var isSyncEnabled = false
    private var modelChangeSubscription: AnyCancellable?
    private var pageColorSubscription: AnyCancellable?
    private var contrastObserver: NSObjectProtocol?

    init() {
        Self.migrateSyncStateIfNeeded()

        let baseDir = AppGroup.containerURL
        let store = DataStore(baseDirectory: baseDir)
        var isSeededRun = false

        #if DEBUG
        // Seed the App Group container from a JSON fixture before AppModel loads.
        // Used by ios-simulator-skill scenarios to start each run from a known
        // state. Set STOW_SEED_FIXTURE=/path/to/fixture.json in the scheme env.
        // STOW_SEED_FIXTURE_JSON carries the fixture itself, for UI tests whose fixture
        // path the simulated app may not be allowed to read.
        let environment = ProcessInfo.processInfo.environment
        if let data = environment["STOW_SEED_FIXTURE_JSON"].map({ Data($0.utf8) })
            ?? environment["STOW_SEED_FIXTURE"].flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            try? data.write(to: baseDir.appendingPathComponent("data.json"))
            isSeededRun = true
        }
        // Starts a UI-test run from the default settings.
        if ProcessInfo.processInfo.environment["STOW_RESET_SETTINGS"] == "1" {
            for key in [LiveActivitySettings.enabledKey, LiveActivitySettings.showsKey, SyncedTintPreference.key,
                        UserDefaultsKeys.lastSelectedWorkspaceId] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults(suiteName: "StowSeededRunCloud")?.removeObject(forKey: SyncedTintPreference.key)
        }
        #endif

        // Fixture runs keep page color on this device too, like their data.
        let tintPreference = isSeededRun
            ? SyncedTintPreference(local: UserDefaults.standard, cloud: UserDefaults(suiteName: "StowSeededRunCloud")!)
            : SyncedTintPreference.shared
        tintPreference.start()
        pageColorStore = PageColorStore(preference: tintPreference)
        shareInbox = ShareInbox()

        let model = AppModel(store: store)
        self.model = model

        // Forward every model change to SwiftUI's invalidation pipeline. Replaces
        // the old refreshTrigger.toggle() pattern — views no longer need to read
        // a sentinel @Published; reading any of viewModel's properties is enough.
        // Only local edits are uploaded; an iCloud fetch or absorbed shares just refresh
        // the UI, the widget and the Live Activity.
        modelChangeSubscription = model.changeOrigins
            .receive(on: DispatchQueue.main)
            .sink { [weak self] origin in
                self?.objectWillChange.send()
                if origin == .local { CloudSyncManager.shared.scheduleLocalChanges() }
                self?.refreshLiveActivity()
                self?.scheduleWidgetReload()
            }
        pageColorSubscription = pageColorStore.$tint
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        contrastObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }

        // Initialize iCloud sync. Fixture runs stay local so seed data never
        // reaches the signed-in iCloud account.
        if !isSeededRun {
            CloudSyncManager.shared.configure(model: model)
            isSyncEnabled = true
        }
        absorbSharedLinks()
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
        LiveActivityController.shared.sync(
            workspace: liveActivitySettings.workspace(in: model),
            enabled: liveActivitySettings.isEnabled,
            force: force
        )
    }

    // MARK: - Page color

    /// The synced choice, as the Settings picker shows it.
    var pageColor: StowTheme.TintMode { pageColorStore.tint }

    /// What pages draw: the choice, softened under Increase Contrast.
    var effectiveTint: StowTheme.TintMode {
        PageColor.effective(pageColorStore.tint, increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled)
    }

    func setPageColor(_ tint: StowTheme.TintMode) {
        pageColorStore.set(tint)
    }

    func background(for colorId: WorkspaceColorId) -> UIColor {
        StowTheme.colors(for: colorId, tint: effectiveTint).surface
    }

    // MARK: - Share extension and widgets

    /// Picks up links the share extension saved while this copy of the state was in memory,
    /// and uploads them. Call on launch, on every foreground and before applying a push.
    func absorbSharedLinks() {
        guard !shareInbox.pending.isEmpty else { return }
        // Absorbing notifies `changeOrigins` as external (refreshing the UI, widget and Live
        // Activity); the links are new to iCloud, so upload them here.
        let added = ShareSaver.absorb(inbox: shareInbox, into: model)
        if added > 0, isSyncEnabled { CloudSyncManager.shared.scheduleLocalChanges() }
    }

    private var widgetReloadTask: Task<Void, Never>?

    /// Widgets showing "Current workspace" follow selection and edits; coalesce bursts.
    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
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
