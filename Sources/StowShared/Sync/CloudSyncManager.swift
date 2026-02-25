import CloudKit
import os
import Foundation
import Security

@MainActor
public final class CloudSyncManager {
    public static let shared = CloudSyncManager()

    private let logger = Logger(subsystem: "com.stow.app", category: "sync")
    private let containerID = "iCloud.com.stow.app"
    private let zoneName = "StowZone"

    private var syncEngine: CKSyncEngine?
    private var model: AppModel?
    private var isMergingRemoteChanges = false

    private lazy var zoneID: CKRecordZone.ID = {
        CKRecordZone.ID(zoneName: zoneName)
    }()

    private init() {}

    public func configure(model: AppModel) {
        self.model = model

        // CKContainer(identifier:) traps without the iCloud entitlement (e.g. ad-hoc signed builds)
        guard Self.hasCloudKitEntitlement(for: containerID) else {
            logger.info("CloudKit entitlement not found, skipping sync setup")
            return
        }

        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase

        // Load persisted sync engine state if available
        let savedStateSerialization = loadSyncEngineState()

        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: savedStateSerialization,
            delegate: self
        )

        syncEngine = CKSyncEngine(configuration)
        logger.info("CloudSyncManager configured")

        // Schedule initial upload of all local data
        scheduleFullUpload()
    }

    // MARK: - Upload Scheduling

    public func scheduleLocalChanges() {
        guard !isMergingRemoteChanges else { return }
        guard let model, let syncEngine else { return }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        // Schedule all workspaces and their nodes for upload
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

    /// Schedules a deletion for a specific record by its UUID.
    public func scheduleDeletion(for id: UUID) {
        guard let syncEngine else { return }
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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

    private static func hasCloudKitEntitlement(for containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        )
        guard let containers = value as? [String] else { return false }
        return containers.contains(containerID)
        #else
        // SecTask APIs are macOS-only; on iOS assume entitlement is present
        return true
        #endif
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

            case .fetchedDatabaseChanges:
                // Zone-level changes handled automatically
                break

            case .fetchedRecordZoneChanges(let fetchedChanges):
                handleFetchedRecordZoneChanges(fetchedChanges)

            case .sentDatabaseChanges:
                break

            case .sentRecordZoneChanges(let sentChanges):
                handleSentRecordZoneChanges(sentChanges)

            case .willFetchChanges:
                break

            case .willFetchRecordZoneChanges:
                break

            case .didFetchChanges:
                break

            case .didFetchRecordZoneChanges:
                break

            case .willSendChanges:
                break

            case .didSendChanges:
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
        // Gather data on the MainActor
        let recordsByID: [CKRecord.ID: CKRecord] = await MainActor.run {
            guard let model else { return [:] }

            var records: [CKRecord.ID: CKRecord] = [:]

            for (index, workspace) in model.workspaces.enumerated() {
                let record = RecordConverter.workspaceToCKRecord(
                    workspace: workspace,
                    sortOrder: index,
                    zoneID: zoneID
                )
                records[record.recordID] = record

                let flatNodes = RecordConverter.flattenNodes(
                    nodes: workspace.items,
                    workspaceId: workspace.id,
                    zoneID: zoneID
                )
                for (nodeRecord, _) in flatNodes {
                    records[nodeRecord.recordID] = nodeRecord
                }
            }

            return records
        }

        guard !recordsByID.isEmpty else { return nil }

        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            if let record = recordsByID[recordID] {
                return record
            } else {
                // Record no longer exists locally; remove from pending
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
        }

        return batch
    }

    // MARK: - Event Handlers

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            logger.info("iCloud account signed in")
            scheduleFullUpload()
        case .signOut:
            logger.info("iCloud account signed out")
        case .switchAccounts:
            logger.info("iCloud account switched")
            scheduleFullUpload()
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let model else { return }

        isMergingRemoteChanges = true
        defer { isMergingRemoteChanges = false }

        // Process modifications
        for modification in changes.modifications {
            let record = modification.record

            switch record.recordType {
            case CKRecordTypes.workspace:
                if let workspace = RecordConverter.ckRecordToWorkspace(record: record) {
                    mergeWorkspace(workspace, into: model)
                }

            case CKRecordTypes.node:
                // Node merging is more complex - we need to rebuild the tree
                // For now, mark that we need a full refresh
                logger.debug("Received node record: \(record.recordID.recordName)")

            default:
                break
            }
        }

        // Process deletions
        for deletion in changes.deletions {
            let recordID = deletion.recordID
            let recordName = recordID.recordName

            if let uuid = UUID(uuidString: recordName) {
                // Try to delete as workspace
                if model.workspaces.contains(where: { $0.id == uuid }) {
                    model.deleteWorkspace(id: uuid)
                } else {
                    // Try to delete as node
                    model.deleteNode(id: uuid)
                }
            }
        }

        model.onChange?()
    }

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Handle conflicts - last-write-wins for now
        for failure in changes.failedRecordSaves {
            if case .serverRecordChanged = failure.error.code {
                // Accept server record by logging and allowing the next fetch to reconcile
                if failure.error.serverRecord != nil {
                    logger.info("Conflict resolved for \(failure.record.recordID.recordName) - accepting server")
                }
            } else {
                logger.error("Failed to save record: \(failure.error.localizedDescription)")
            }
        }
    }

    // MARK: - Merge Helpers

    private func mergeWorkspace(_ remote: Workspace, into model: AppModel) {
        if model.workspaces.contains(where: { $0.id == remote.id }) {
            // Update existing workspace
            model.renameWorkspace(id: remote.id, newName: remote.name)
            model.updateWorkspaceColor(id: remote.id, colorId: remote.colorId)
        } else {
            // Add new workspace from remote
            model.insertWorkspaceFromSync(remote)
        }
    }
}
