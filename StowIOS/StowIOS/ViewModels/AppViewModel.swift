import SwiftUI
import UIKit
import Combine
import WidgetKit
import StowShared

@MainActor
final class AppViewModel: ObservableObject {
    let model: AppModel
    @Published var searchQuery = ""
    /// The Edit Workspace sheet opened from a page (its title, or swiping past the last
    /// one) or the iPad sidebar. The Workspaces sheet presents its own.
    @Published var workspaceEditor: WorkspaceEditorModel?
    /// The one Undo toast.
    let undoToasts = UndoToastCenter()
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

        // Favicons used to live in the app's private Application Support, where the
        // widget and the Live Activity can't read them.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let privateIcons = appSupport.appendingPathComponent("Stow/Icons", isDirectory: true)
            FaviconStorage.moveIcons(from: privateIcons, to: store.iconsDirectory())
        }
        FaviconService.shared.useIcons(in: baseDir)

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
        let workspace = liveActivitySettings.workspace(in: model)
        LiveActivityController.shared.sync(
            workspace: workspace,
            identity: workspaceIdentities[workspace.id],
            enabled: liveActivitySettings.isEnabled,
            force: force
        )
    }

    /// Every workspace's badge, resolved together so letters stay distinct.
    var workspaceIdentities: [UUID: WorkspaceTileIdentity] {
        WorkspaceBadge.identities(for: model.workspaces, iconsDirectory: AppGroup.iconsDirectory)
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

    /// Opens the Edit Workspace sheet on a workspace.
    func editWorkspace(id: UUID) {
        workspaceEditor = WorkspaceEditorModel(editing: id, in: model)
    }

    /// Opens the Edit Workspace sheet with an empty, focused name; nothing exists until
    /// it's created there.
    func beginNewWorkspace() {
        workspaceEditor = WorkspaceEditorModel(creatingIn: model)
    }

    // MARK: - Items

    /// A row that should open in rename as soon as it appears (a new folder).
    @Published var pendingRenameId: UUID?

    /// Adds an "Untitled" folder (the Mac's default name) and starts its rename.
    func addFolderAndBeginRename(parentId: UUID?) {
        if let parentId { model.setFolderExpanded(id: parentId, isExpanded: true) }
        pendingRenameId = model.addFolder(name: NodeDefaults.folderName, parentId: parentId)
    }

    /// Archives the items with an Undo toast; shake or a three-finger swipe undoes too.
    func archive(_ ids: [UUID], undoManager: UndoManager?) {
        ItemUndo.archive(ids, model: model, toasts: undoToasts, undoManager: undoManager)
    }

    /// Deletes the item for good with an Undo toast; its icon files stay on disk until the
    /// toast is gone so an undo brings it back whole.
    func deletePermanently(_ id: UUID, undoManager: UndoManager?) {
        ItemUndo.deletePermanently(id, model: model, toasts: undoToasts, undoManager: undoManager)
    }
}
