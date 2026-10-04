import CloudKit
import os
import Foundation

/// Why sync is or isn't running. UIs read this to show a "sync off" state
/// instead of silently degrading.
public enum SyncAvailability: Equatable, Sendable {
    case notConfigured
    case active
    /// The build lacks the provisioning profile CloudKit needs (unprovisioned macOS dev builds).
    case disabledNoProvisioningProfile
}

@MainActor
public final class CloudSyncManager {
    public static let shared = CloudSyncManager()

    public private(set) var availability: SyncAvailability = .notConfigured {
        didSet { NotificationCenter.default.post(name: .cloudSyncStatusChanged, object: nil) }
    }
    /// The iCloud account signed out while Stow was running.
    public private(set) var isSignedOut = false

    /// When a fetch or upload last finished cleanly. Kept across launches so a status
    /// line can say "Synced 2 min ago" right after the app starts.
    public private(set) var lastSyncDate: Date? = UserDefaults.standard.object(forKey: CloudSyncManager.lastSyncDateKey) as? Date
    /// The most recent failure, cleared by the next success.
    public private(set) var lastSyncError: String?
    /// Posted on the default center whenever `lastSyncDate` or `lastSyncError` changes,
    /// alongside `.cloudSyncStatusChanged`, which the Mac's status line observes.
    public static let statusDidChangeNotification = Notification.Name("StowCloudSyncStatusDidChange")
    private static let lastSyncDateKey = "StowLastCloudSyncDate"

    private let logger = Logger(subsystem: "com.stow.app", category: "sync")
    private let containerID = "iCloud.com.stow.app"
    private let zoneName = "StowZone"

    private var syncEngine: CKSyncEngine?
    private var model: AppModel?
    private var isMergingRemoteChanges = false
    private var workspaceIdRedirects: [UUID: UUID] = [:]

    /// Cache of last-known server records (full CKRecord), keyed by record name (UUID string).
    /// Used for change detection (skip unchanged uploads) and conflict avoidance (preserve change tags).
    private var lastKnownRecords: [String: Data] = [:]

    /// Sort orders accumulated across multiple fetch batches within a single fetch cycle.
    /// Applied once in didFetchChanges to ensure correct ordering across all batches.
    private var pendingWorkspaceSortOrders: [UUID: Int] = [:]
    private var pendingNodeSortOrders: [UUID: Int] = [:]

    /// Nodes that failed to insert because their parent folder wasn't available yet.
    /// Accumulated across batches and retried in didFetchChanges when all records have arrived.
    private struct DeferredNode {
        let node: Node
        let workspaceId: UUID
        let parentId: UUID?
        let deduplicateLinks: Bool
        let sortOrder: Int
    }
    private var deferredNodes: [DeferredNode] = []

    /// Periodic poll timer for environments without push notifications.
    private var pollTimer: Timer?

    private lazy var zoneID: CKRecordZone.ID = {
        CKRecordZone.ID(zoneName: zoneName)
    }()

    private init() {}

    public func configure(model: AppModel) {
        self.model = model

        #if os(macOS)
        // CKContainer(identifier:) crashes with SIGTRAP on macOS Tahoe in builds
        // without a provisioning profile (e.g. development builds outside Xcode).
        // macOS-only: iOS builds are provisioned through embedded.mobileprovision
        // or App Store signing, so this file never exists there and the guard
        // would disable sync on every iOS build.
        guard Bundle.main.path(forResource: "embedded", ofType: "provisionprofile") != nil else {
            availability = .disabledNoProvisioningProfile
            logger.warning("No provisioning profile — iCloud sync disabled for this build")
            return
        }
        #endif

        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase

        // One-time migration: clear stale sync state to force a full re-fetch.
        // Previous versions could silently drop node records during fetch (parent-child ordering),
        // advancing the token past changes that were never applied locally.
        migrateSyncStateIfNeeded()

        let savedStateSerialization = loadSyncEngineState()
        lastKnownRecords = loadLastKnownRecords()

        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: savedStateSerialization,
            delegate: self
        )

        syncEngine = CKSyncEngine(configuration)
        availability = .active
        logger.info("CloudSyncManager configured with container=\(self.containerID, privacy: .public) zone=\(self.zoneName, privacy: .public)")

        // Ensure the custom zone exists
        syncEngine!.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])

        // Only upload all local data on first launch (no cached state).
        // On subsequent launches, CKSyncEngine auto-fetches remote changes.
        if savedStateSerialization == nil {
            scheduleFullUpload()
        }

        // Poll for changes while the app is in front (covers environments without push
        // notifications); hosts fetch once on each activation themselves.
        pollsWhileActive = true
        observeActivation()
        appBecameActive()
    }

    // MARK: - Poll

    private var pollsWhileActive = false
    private var observesActivation = false

    /// Whether the 30s poll is running: only while sync is on and the app is active.
    var isPolling: Bool { pollTimer != nil }

    private func observeActivation() {
        guard !observesActivation else { return }
        observesActivation = true
        let center = NotificationCenter.default
        #if os(macOS)
        let active = Notification.Name("NSApplicationDidBecomeActiveNotification")
        let resigned = Notification.Name("NSApplicationDidResignActiveNotification")
        #else
        let active = Notification.Name("UIApplicationDidBecomeActiveNotification")
        let resigned = Notification.Name("UIApplicationWillResignActiveNotification")
        #endif
        center.addObserver(forName: active, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudSyncManager.shared.appBecameActive() }
        }
        center.addObserver(forName: resigned, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudSyncManager.shared.appResignedActive() }
        }
    }

    func appBecameActive() {
        guard pollsWhileActive, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchChanges()
            }
        }
    }

    func appResignedActive() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setPollsWhileActiveForTesting(_ polls: Bool) {
        pollsWhileActive = polls
        if !polls { appResignedActive() }
    }

    // MARK: - Fetch

    /// Manually triggers fetching remote changes. Call when the app comes to foreground.
    public func fetchChanges() {
        guard let syncEngine else { return }
        Task {
            do {
                try await syncEngine.fetchChanges()
            } catch {
                recordSyncFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Status

    func recordSyncSuccess(at date: Date = Date()) {
        lastSyncDate = date
        lastSyncError = nil
        UserDefaults.standard.set(date, forKey: Self.lastSyncDateKey)
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: .cloudSyncStatusChanged, object: nil)
    }

    func recordSyncFailure(_ message: String) {
        lastSyncError = message
        NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: .cloudSyncStatusChanged, object: nil)
    }

    func resetSyncStatusForTesting() {
        lastSyncDate = nil
        lastSyncError = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncDateKey)
    }

    // MARK: - Upload Scheduling

    public func scheduleLocalChanges() {
        guard !isMergingRemoteChanges else { return }
        guard let model, let syncEngine else { return }

        let wsDesc = model.workspaces.enumerated().map { "\($0):\($1.name)(\($1.items.count) items)" }.joined(separator: ", ")
        logger.info("[UPLOAD] scheduleLocalChanges workspaces=[\(wsDesc, privacy: .public)]")

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for workspace in model.workspaces {
            let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: zoneID)
            pendingChanges.append(.saveRecord(recordID))
            collectNodeChanges(from: workspace.items, into: &pendingChanges)
        }

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
        }
    }

    private func scheduleFullUpload() {
        guard let model, let syncEngine else { return }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        for workspace in model.workspaces {
            let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: zoneID)
            pendingChanges.append(.saveRecord(recordID))
            collectNodeChanges(from: workspace.items, into: &pendingChanges)
        }

        if !pendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
        }
    }

    private func collectNodeChanges(from nodes: [Node], into changes: inout [CKSyncEngine.PendingRecordZoneChange]) {
        for node in nodes {
            let recordID = CKRecord.ID(recordName: node.id.uuidString, zoneID: zoneID)
            changes.append(.saveRecord(recordID))
            if case .folder(let folder) = node {
                collectNodeChanges(from: folder.children, into: &changes)
            }
        }
    }

    public func scheduleDeletion(for id: UUID) {
        guard let syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        lastKnownRecords.removeValue(forKey: id.uuidString)
    }

    // MARK: - Record Cache

    /// Returns a full CKRecord restored from cache (system fields + user fields), or nil if not cached.
    /// Preserves the server's changeTag so uploads don't conflict and allows field comparison.
    private func cachedRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let data = lastKnownRecords[recordID.recordName] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }

    /// Caches a full CKRecord (system fields + user fields) for conflict avoidance and change detection.
    private func cacheRecord(_ record: CKRecord) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true) {
            lastKnownRecords[record.recordID.recordName] = data
        }
    }

    /// Removes cached record (used when the server version is invalidated).
    private func clearCachedRecord(for recordID: CKRecord.ID) {
        lastKnownRecords.removeValue(forKey: recordID.recordName)
    }

    /// Compares user-defined field values between two records. Returns true if all fields in
    /// `newRecord` match `existingRecord`. Used to skip redundant uploads.
    private func recordFieldsMatch(_ existingRecord: CKRecord, _ newRecord: CKRecord) -> Bool {
        let keys = newRecord.allKeys()
        guard !keys.isEmpty else { return true }
        for key in keys {
            let existingValue = existingRecord[key] as? NSObject
            let newValue = newRecord[key] as? NSObject
            if existingValue != newValue { return false }
        }
        return true
    }

    // MARK: - Persistence

    private func loadSyncEngineState() -> CKSyncEngine.State.Serialization? {
        let url = syncEngineStateURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveSyncEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        let url = syncEngineStateURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(serialization) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func syncEngineStateURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Stow/SyncEngine/state.json")
    }

    private func lastKnownRecordsURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Stow/SyncEngine/lastKnownRecords.plist")
    }

    private func loadLastKnownRecords() -> [String: Data] {
        let url = lastKnownRecordsURL()
        guard let data = try? Data(contentsOf: url),
              let dict = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSDictionary.self, NSString.self, NSData.self],
                  from: data
              ) as? [String: Data] else {
            return [:]
        }
        return dict
    }

    private func saveLastKnownRecords() {
        let url = lastKnownRecordsURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: lastKnownRecords as NSDictionary,
            requiringSecureCoding: true
        ) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Clears stale sync engine state and record cache so the next launch
    /// does a full re-fetch from the server. Runs once per migration key.
    private func migrateSyncStateIfNeeded() {
        let key = "syncStateReset_nodeRetryFix_v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let stateURL = syncEngineStateURL()
        let recordsURL = lastKnownRecordsURL()
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: recordsURL)
        UserDefaults.standard.set(true, forKey: key)
        logger.info("Cleared sync engine state for full re-fetch (one-time migration)")
    }

}

// MARK: - CKSyncEngineDelegate

extension CloudSyncManager: CKSyncEngineDelegate {
    public nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run {
            switch event {
            case .stateUpdate(let stateUpdate):
                saveSyncEngineState(stateUpdate.stateSerialization)

            case .accountChange(let accountChange):
                handleAccountChange(accountChange)

            case .fetchedDatabaseChanges(let dbChanges):
                handleFetchedDatabaseChanges(dbChanges)

            case .fetchedRecordZoneChanges(let fetchedChanges):
                handleFetchedRecordZoneChanges(fetchedChanges)

            case .sentDatabaseChanges:
                break

            case .sentRecordZoneChanges(let sentChanges):
                handleSentRecordZoneChanges(sentChanges)

            case .willFetchChanges:
                handleWillFetchChanges()

            case .didFetchChanges:
                handleDidFetchChanges()
                noteSynced()

            case .didSendChanges:
                noteSynced()

            case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges:
                break

            @unknown default:
                logger.warning("Unknown sync event")
            }
        }
    }

    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let recordsByID: [CKRecord.ID: CKRecord] = await MainActor.run {
            guard let model else { return [:] }

            var records: [CKRecord.ID: CKRecord] = [:]

            for (index, workspace) in model.workspaces.enumerated() {
                let newRecord = RecordConverter.workspaceToCKRecord(
                    workspace: workspace,
                    sortOrder: index,
                    zoneID: zoneID
                )
                let recordID = newRecord.recordID

                if let cached = cachedRecord(for: recordID) {
                    // Skip if field values haven't changed (avoids redundant server writes)
                    if recordFieldsMatch(cached, newRecord) {
                        self.logger.info("[BATCH] skip unchanged workspace \(workspace.name, privacy: .public) sortOrder=\(index, privacy: .public)")
                        continue
                    }
                    // Use cached record as base to preserve server change token
                    for key in newRecord.allKeys() {
                        cached[key] = newRecord[key]
                    }
                    records[recordID] = cached
                    self.logger.info("[BATCH] upload workspace \(workspace.name, privacy: .public) sortOrder=\(index, privacy: .public) (changed)")
                } else {
                    // New record — no cached version, must upload
                    records[recordID] = newRecord
                    self.logger.info("[BATCH] upload workspace \(workspace.name, privacy: .public) sortOrder=\(index, privacy: .public) (new)")
                }

                let flatNodes = RecordConverter.flattenNodes(
                    nodes: workspace.items,
                    workspaceId: workspace.id,
                    zoneID: zoneID
                )
                for (newNodeRecord, node) in flatNodes {
                    let nodeRecordID = newNodeRecord.recordID
                    let nodeSortOrder = newNodeRecord[CKNodeFields.sortOrder] as? Int ?? -1

                    if let cachedNode = cachedRecord(for: nodeRecordID) {
                        if recordFieldsMatch(cachedNode, newNodeRecord) {
                            continue
                        }
                        for key in newNodeRecord.allKeys() {
                            cachedNode[key] = newNodeRecord[key]
                        }
                        records[nodeRecordID] = cachedNode
                        self.logger.info("[BATCH] upload node \(node.displayName, privacy: .public) sortOrder=\(nodeSortOrder, privacy: .public) in \(workspace.name, privacy: .public) (changed)")
                    } else {
                        records[nodeRecordID] = newNodeRecord
                        self.logger.info("[BATCH] upload node \(node.displayName, privacy: .public) sortOrder=\(nodeSortOrder, privacy: .public) in \(workspace.name, privacy: .public) (new)")
                    }
                }
            }

            return records
        }

        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        // Remove pending changes for records that haven't changed
        let unchangedIDs = pendingChanges.compactMap { change -> CKRecord.ID? in
            guard case .saveRecord(let recordID) = change, recordsByID[recordID] == nil else { return nil }
            // Only remove if the record exists in the model but was skipped (unchanged).
            // If the record is genuinely missing from the model, it was already handled elsewhere.
            return recordID
        }
        if !unchangedIDs.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: unchangedIDs.map { .saveRecord($0) })
        }

        guard !recordsByID.isEmpty else { return nil }

        let filteredPending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: filteredPending) { recordID in
            if let record = recordsByID[recordID] {
                return record
            } else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
        }

        return batch
    }

    // MARK: - Event Handlers

    private func noteSynced() {
        isSignedOut = false
        recordSyncSuccess()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in")
            lastKnownRecords.removeAll()
            saveLastKnownRecords()
            scheduleFullUpload()
        case .signOut:
            logger.info("iCloud account signed out")
            isSignedOut = true
            recordSyncFailure("Not signed in to iCloud")
            NotificationCenter.default.post(name: .cloudSyncStatusChanged, object: nil)
        case .switchAccounts:
            logger.info("iCloud account switched")
            lastKnownRecords.removeAll()
            saveLastKnownRecords()
            scheduleFullUpload()
        @unknown default:
            break
        }
    }

    private func handleWillFetchChanges() {
        isMergingRemoteChanges = true
        pendingWorkspaceSortOrders.removeAll()
        pendingNodeSortOrders.removeAll()
        deferredNodes.removeAll()
        workspaceIdRedirects.removeAll()
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let model else { return }

        logger.info("Fetched \(changes.modifications.count, privacy: .public) modifications, \(changes.deletions.count, privacy: .public) deletions")

        // Process workspace records before node records so the workspace exists
        // when we try to insert its nodes.
        // Within nodes, process those without parents first (top-level before children).
        let sortedModifications = changes.modifications.sorted { a, b in
            let aIsWorkspace = a.record.recordType == CKRecordTypes.workspace
            let bIsWorkspace = b.record.recordType == CKRecordTypes.workspace
            if aIsWorkspace != bIsWorkspace { return aIsWorkspace }
            // Both nodes: no-parent before has-parent
            if !aIsWorkspace && !bIsWorkspace {
                let aHasParent = a.record[CKNodeFields.parentNodeRef] != nil
                let bHasParent = b.record[CKNodeFields.parentNodeRef] != nil
                if aHasParent != bHasParent { return !aHasParent }
            }
            return false
        }

        for modification in sortedModifications {
            let record = modification.record
            cacheRecord(record)

            switch record.recordType {
            case CKRecordTypes.workspace:
                if let workspace = RecordConverter.ckRecordToWorkspace(record: record) {
                    let sortOrder = record[CKWorkspaceFields.sortOrder] as? Int ?? -1
                    logger.info("[FETCH] workspace \(workspace.name, privacy: .public) id=\(workspace.id.uuidString.prefix(8), privacy: .public) sortOrder=\(sortOrder, privacy: .public)")
                    mergeWorkspace(workspace, into: model)
                    if sortOrder >= 0 {
                        let resolvedId = workspaceIdRedirects[workspace.id] ?? workspace.id
                        pendingWorkspaceSortOrders[resolvedId] = sortOrder
                    }
                }

            case CKRecordTypes.node:
                if let node = RecordConverter.ckRecordToNode(record: record),
                   let workspaceRef = record[CKNodeFields.workspaceRef] as? CKRecord.Reference,
                   let rawWorkspaceId = UUID(uuidString: workspaceRef.recordID.recordName) {
                    let workspaceId = workspaceIdRedirects[rawWorkspaceId] ?? rawWorkspaceId
                    let deduplicateLinks = workspaceIdRedirects[rawWorkspaceId] != nil
                    let parentId: UUID?
                    if let parentRef = record[CKNodeFields.parentNodeRef] as? CKRecord.Reference {
                        parentId = UUID(uuidString: parentRef.recordID.recordName)
                    } else {
                        parentId = nil
                    }
                    let sortOrder = record[CKNodeFields.sortOrder] as? Int ?? -1
                    logger.info("[FETCH] node \(node.displayName, privacy: .public) sortOrder=\(sortOrder, privacy: .public) wsId=\(workspaceId.uuidString.prefix(8), privacy: .public)")
                    let ok = model.upsertNodeFromSync(node: node, workspaceId: workspaceId, parentId: parentId, deduplicateLinks: deduplicateLinks)
                    if !ok {
                        // Parent folder may arrive in a later batch; defer and retry in didFetchChanges
                        deferredNodes.append(DeferredNode(node: node, workspaceId: workspaceId, parentId: parentId, deduplicateLinks: deduplicateLinks, sortOrder: sortOrder))
                        logger.info("[FETCH] deferred node \(node.displayName, privacy: .public) (parent not yet available)")
                    }
                    if sortOrder >= 0 {
                        pendingNodeSortOrders[node.id] = sortOrder
                    }
                }

            default:
                break
            }
        }

        for deletion in changes.deletions {
            let recordID = deletion.recordID
            lastKnownRecords.removeValue(forKey: recordID.recordName)

            if let uuid = UUID(uuidString: recordID.recordName) {
                if model.workspaces.contains(where: { $0.id == uuid }) {
                    model.deleteWorkspaceFromSync(id: uuid)
                } else {
                    model.deleteNodeFromAnyWorkspace(id: uuid)
                }
            }
        }
    }

    private func handleDidFetchChanges() {
        guard let model else {
            isMergingRemoteChanges = false
            return
        }

        // Retry deferred nodes now that all batches have been processed
        if !deferredNodes.isEmpty {
            logger.info("[FETCH] retrying \(self.deferredNodes.count, privacy: .public) deferred nodes")
            var remaining = deferredNodes
            var retries = 0
            while !remaining.isEmpty && retries < 5 {
                var stillFailed: [DeferredNode] = []
                for entry in remaining {
                    let ok = model.upsertNodeFromSync(node: entry.node, workspaceId: entry.workspaceId, parentId: entry.parentId, deduplicateLinks: entry.deduplicateLinks)
                    if !ok {
                        stillFailed.append(entry)
                    } else {
                        logger.info("[FETCH] retried node \(entry.node.displayName, privacy: .public) ok")
                    }
                }
                if stillFailed.count == remaining.count { break }
                remaining = stillFailed
                retries += 1
            }
            // Fall back: insert at top-level rather than losing the node
            for entry in remaining {
                logger.warning("[FETCH] inserting node \(entry.node.displayName, privacy: .public) at top level (parent not found)")
                model.upsertNodeFromSync(node: entry.node, workspaceId: entry.workspaceId, parentId: nil, deduplicateLinks: entry.deduplicateLinks)
            }
            deferredNodes.removeAll()
        }

        // Log state before reorder
        let beforeDesc = model.workspaces.enumerated().map { "\($0):\($1.name)(\($1.items.count) items)" }.joined(separator: ", ")
        logger.info("[REORDER] before=[\(beforeDesc, privacy: .public)]")
        for (wsId, order) in pendingWorkspaceSortOrders {
            logger.info("[REORDER] pending ws \(wsId.uuidString.prefix(8), privacy: .public) -> sortOrder=\(order, privacy: .public)")
        }
        logger.info("[REORDER] pendingNodeSortOrders count=\(self.pendingNodeSortOrders.count, privacy: .public)")

        // Apply accumulated sort orders from all batches
        if !pendingWorkspaceSortOrders.isEmpty {
            model.reorderWorkspacesFromSync(sortOrders: pendingWorkspaceSortOrders)
        }
        if !pendingNodeSortOrders.isEmpty {
            model.reorderNodesFromSync(sortOrders: pendingNodeSortOrders)
        }

        // Log state after reorder
        let afterDesc = model.workspaces.enumerated().map { "\($0):\($1.name)(\($1.items.count) items)" }.joined(separator: ", ")
        logger.info("[REORDER] after=[\(afterDesc, privacy: .public)]")
        for ws in model.workspaces {
            let itemNames = ws.items.map { $0.displayName }.joined(separator: ", ")
            logger.info("[REORDER] ws \(ws.name, privacy: .public) items=[\(itemNames, privacy: .public)]")
        }

        pendingWorkspaceSortOrders.removeAll()
        pendingNodeSortOrders.removeAll()
        saveLastKnownRecords()
        Self.notifyMergeFinished(model)
        isMergingRemoteChanges = false
        recordSyncSuccess()
    }

    /// Tells the model's subscribers that a fetch cycle changed it. The change is marked
    /// external, so hosts refresh without scheduling an upload of what just arrived.
    static func notifyMergeFinished(_ model: AppModel) {
        model.notifyExternalChange()
    }

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        guard let syncEngine else { return }

        var newPendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var newPendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
        var unrecoveredFailure: String?
        var appliedServerRecord = false

        // Cache successfully saved records
        for savedRecord in changes.savedRecords {
            cacheRecord(savedRecord)
            if savedRecord.recordType == CKRecordTypes.workspace {
                let name = savedRecord[CKWorkspaceFields.name] as? String ?? "?"
                let sortOrder = savedRecord[CKWorkspaceFields.sortOrder] as? Int ?? -1
                logger.info("[SENT] saved workspace \(name, privacy: .public) sortOrder=\(sortOrder, privacy: .public)")
            }
        }

        for failure in changes.failedRecordSaves {
            let failedRecord = failure.record

            switch failure.error.code {
            case .serverRecordChanged:
                // Server has a newer version. Accept the server's data (server wins).
                // Apply it to the local model like a fetch, then cache the server record.
                if let serverRecord = failure.error.serverRecord {
                    cacheRecord(serverRecord)
                    applyServerRecord(serverRecord)
                    appliedServerRecord = true
                    logger.info("Conflict for \(failedRecord.recordID.recordName, privacy: .public) - accepted server version")
                }

            case .zoneNotFound:
                // Zone was deleted or doesn't exist. Re-create and retry.
                let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
                newPendingDatabaseChanges.append(.saveZone(zone))
                newPendingChanges.append(.saveRecord(failedRecord.recordID))
                clearCachedRecord(for: failedRecord.recordID)

            case .unknownItem:
                // Record was deleted on server. Only re-upload if it still exists locally
                // (user created it again). Otherwise accept the server deletion.
                clearCachedRecord(for: failedRecord.recordID)
                if recordExistsInLocalModel(failedRecord.recordID) {
                    newPendingChanges.append(.saveRecord(failedRecord.recordID))
                }

            default:
                logger.error("Failed to save \(failedRecord.recordID.recordName, privacy: .public) code=\(failure.error.code.rawValue, privacy: .public) desc=\(failure.error.localizedDescription, privacy: .public)")
                unrecoveredFailure = failure.error.localizedDescription
            }
        }
        if appliedServerRecord, let model {
            Self.notifyMergeFinished(model)
        }
        if let unrecoveredFailure {
            recordSyncFailure(unrecoveredFailure)
        } else if !changes.savedRecords.isEmpty || !changes.deletedRecordIDs.isEmpty {
            recordSyncSuccess()
        }

        if !newPendingDatabaseChanges.isEmpty {
            syncEngine.state.add(pendingDatabaseChanges: newPendingDatabaseChanges)
        }
        if !newPendingChanges.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: newPendingChanges)
        }

        saveLastKnownRecords()
    }

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in changes.deletions {
            switch deletion.reason {
            case .purged, .encryptedDataReset:
                // User cleared iCloud data or account recovery — clear sync state and re-upload
                logger.info("Zone \(deletion.zoneID.zoneName, privacy: .public) \(String(describing: deletion.reason), privacy: .public) — resetting sync state")
                lastKnownRecords.removeAll()
                saveLastKnownRecords()
                scheduleFullUpload()

            case .deleted:
                // Zone was programmatically deleted
                logger.info("Zone \(deletion.zoneID.zoneName, privacy: .public) deleted")
                lastKnownRecords.removeAll()
                saveLastKnownRecords()

            @unknown default:
                break
            }
        }
    }

    // MARK: - Merge Helpers

    private func recordExistsInLocalModel(_ recordID: CKRecord.ID) -> Bool {
        guard let model, let uuid = UUID(uuidString: recordID.recordName) else { return false }
        // Check workspaces
        if model.workspaces.contains(where: { $0.id == uuid }) { return true }
        // Check nodes across all workspaces
        for workspace in model.workspaces {
            if model.findNode(id: uuid, in: workspace.items) != nil { return true }
        }
        return false
    }

    private func mergeWorkspace(_ remote: Workspace, into model: AppModel) {
        if model.workspaces.contains(where: { $0.id == remote.id }) {
            model.updateWorkspaceFromSync(remote)
        } else if let existing = model.workspaces.first(where: { $0.name == remote.name }) {
            // Same name, different UUID — merge into existing workspace and delete remote orphan
            workspaceIdRedirects[remote.id] = existing.id
            model.mergeWorkspaceMetadataFromSync(remote: remote, intoWorkspaceId: existing.id)
            // Delete the orphaned remote workspace record from the server
            scheduleDeletion(for: remote.id)
        } else {
            model.insertWorkspaceFromSync(remote)
        }
    }

    /// Applies a server record's data to the local model (used for conflict resolution).
    private func applyServerRecord(_ record: CKRecord) {
        guard let model else { return }

        switch record.recordType {
        case CKRecordTypes.workspace:
            if let workspace = RecordConverter.ckRecordToWorkspace(record: record) {
                if model.workspaces.contains(where: { $0.id == workspace.id }) {
                    model.updateWorkspaceFromSync(workspace)
                }
            }
        case CKRecordTypes.node:
            if let node = RecordConverter.ckRecordToNode(record: record),
               let workspaceRef = record[CKNodeFields.workspaceRef] as? CKRecord.Reference,
               let workspaceId = UUID(uuidString: workspaceRef.recordID.recordName) {
                let parentId: UUID?
                if let parentRef = record[CKNodeFields.parentNodeRef] as? CKRecord.Reference {
                    parentId = UUID(uuidString: parentRef.recordID.recordName)
                } else {
                    parentId = nil
                }
                model.upsertNodeFromSync(node: node, workspaceId: workspaceId, parentId: parentId)
            }
        default:
            break
        }
    }
}
