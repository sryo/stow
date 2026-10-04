import XCTest
@testable import StowShared

/// Covers the `*FromSync` family on `AppModel` — the merge entry points
/// invoked by `CloudSyncManager` when it receives remote changes. Drives
/// the model directly with Node/Workspace fixtures; CKRecord-to-Node
/// conversion is exercised at a higher layer (RecordConverter).
final class CloudSyncMergeTests: XCTestCase {

    private var tempDir: URL!
    private var model: AppModel!
    private var workspaceId: UUID { model.workspaces[0].id }

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeLink(id: UUID = UUID(), url: String = "https://x.test") -> Node {
        .link(Link(id: id, title: url, url: url, faviconPath: nil))
    }

    private func makeFolder(id: UUID = UUID(), name: String = "f", children: [Node] = []) -> Node {
        .folder(Folder(id: id, name: name, children: children, isExpanded: true))
    }

    // MARK: - upsertNodeFromSync — inserts

    func testUpsert_insertsNewTopLevelNode() {
        let id = UUID()
        let accepted = model.upsertNodeFromSync(node: makeLink(id: id), workspaceId: workspaceId, parentId: nil)
        XCTAssertTrue(accepted)
        XCTAssertNotNil(model.nodeById(id))
    }

    func testUpsert_insertsUnderExistingParent() {
        let parentId = model.addFolder(name: "p", parentId: nil)
        let leafId = UUID()
        let accepted = model.upsertNodeFromSync(node: makeLink(id: leafId), workspaceId: workspaceId, parentId: parentId)
        XCTAssertTrue(accepted)
        guard let parent = model.nodeById(parentId), case .folder(let folder) = parent else {
            XCTFail(); return
        }
        XCTAssertTrue(folder.children.contains(where: { $0.id == leafId }))
    }

    func testUpsert_returnsFalseWhenParentNotYetArrived() {
        let pendingParent = UUID()
        let accepted = model.upsertNodeFromSync(node: makeLink(), workspaceId: workspaceId, parentId: pendingParent)
        XCTAssertFalse(accepted, "Caller should retry once the parent record arrives")
    }

    func testUpsert_returnsFalseForUnknownWorkspace() {
        let accepted = model.upsertNodeFromSync(node: makeLink(), workspaceId: UUID(), parentId: nil)
        XCTAssertFalse(accepted)
    }

    // MARK: - upsertNodeFromSync — updates

    func testUpsert_replacesExistingLinkInPlace() {
        let id = model.addLink(urlString: "https://before", title: "before", parentId: nil)
        let updated = Link(id: id, title: "after", url: "https://after", faviconPath: nil)

        _ = model.upsertNodeFromSync(node: .link(updated), workspaceId: workspaceId, parentId: nil)

        guard case .link(let l) = model.nodeById(id)! else { XCTFail(); return }
        XCTAssertEqual(l.title, "after")
        XCTAssertEqual(l.url, "https://after")
    }

    func testUpsert_preservesFolderChildrenOnFolderUpdate() {
        let folderId = model.addFolder(name: "before", parentId: nil)
        let childId = model.addLink(urlString: "https://kept", title: "kept", parentId: folderId)

        // Remote sends an updated folder with NO children — local children must be preserved.
        let renamed = Folder(id: folderId, name: "after", children: [], isExpanded: false)
        _ = model.upsertNodeFromSync(node: .folder(renamed), workspaceId: workspaceId, parentId: nil)

        guard case .folder(let f) = model.nodeById(folderId)! else { XCTFail(); return }
        XCTAssertEqual(f.name, "after")
        XCTAssertEqual(f.children.first?.id, childId)
    }

    // MARK: - upsertNodeFromSync — link URL dedup

    func testUpsert_skipsLinkWithDuplicateURLWhenDedupActive() {
        _ = model.addLink(urlString: "https://same", title: "local", parentId: nil)
        let remoteId = UUID()
        let remote = Link(id: remoteId, title: "remote", url: "https://same", faviconPath: nil)

        let accepted = model.upsertNodeFromSync(
            node: .link(remote),
            workspaceId: workspaceId,
            parentId: nil,
            deduplicateLinks: true
        )

        XCTAssertTrue(accepted, "Dedup short-circuit returns true so caller doesn't retry")
        XCTAssertNil(model.nodeById(remoteId), "Duplicate URL link should not have been inserted")
    }

    func testUpsert_allowsLinkWithDuplicateURLWhenDedupOff() {
        _ = model.addLink(urlString: "https://same", title: "local", parentId: nil)
        let remoteId = UUID()
        let remote = Link(id: remoteId, title: "remote", url: "https://same", faviconPath: nil)

        _ = model.upsertNodeFromSync(node: .link(remote), workspaceId: workspaceId, parentId: nil)

        XCTAssertNotNil(model.nodeById(remoteId))
    }

    // MARK: - mergeWorkspaceMetadataFromSync

    func testMergeWorkspaceMetadata_remoteWinsOnColorAndBrowserProfile() {
        let local = model.workspaces[0]
        model.updateWorkspaceColor(id: local.id, colorId: .ocean)
        model.updateWorkspaceBrowserProfile(id: local.id, bundleId: "com.example.browser", profile: "Local")

        let remote = Workspace(
            id: UUID(),
            name: local.name,
            colorId: .ember,
            items: [],
            browserProfiles: ["com.example.browser": "Remote", "com.other.browser": "Other"]
        )

        model.mergeWorkspaceMetadataFromSync(remote: remote, intoWorkspaceId: local.id)

        let merged = model.workspaces[0]
        XCTAssertEqual(merged.colorId, .ember, "Remote color wins")
        XCTAssertEqual(merged.browserProfiles["com.example.browser"], "Remote", "Remote wins on conflict")
        XCTAssertEqual(merged.browserProfiles["com.other.browser"], "Other", "Remote-only profiles added")
    }

    func testUpdateFromSync_keepsThisMacsProfilesWhenTheRecordHasNone() {
        let local = model.workspaces[0]
        model.updateWorkspaceBrowserProfile(id: local.id, bundleId: "com.google.Chrome", profile: "Profile 1")
        var remote = local
        remote.name = "Renamed elsewhere"
        remote.browserProfiles = [:]
        model.updateWorkspaceFromSync(remote)
        XCTAssertEqual(model.workspaces[0].name, "Renamed elsewhere")
        XCTAssertEqual(model.workspaces[0].browserProfiles, ["com.google.Chrome": "Profile 1"])
    }

    // MARK: - reorder

    func testReorderWorkspacesFromSync_serverOrderApplies() {
        let secondId = model.createWorkspace(name: "second", colorId: .moss)
        let thirdId = model.createWorkspace(name: "third", colorId: .ruby)
        let firstId = model.workspaces[0].id

        // Server says: third (0), first (1), second (2)
        model.reorderWorkspacesFromSync(sortOrders: [thirdId: 0, firstId: 1, secondId: 2])

        XCTAssertEqual(model.workspaces.map(\.id), [thirdId, firstId, secondId])
    }

    func testReorderNodesFromSync_topLevelAndNested() {
        let folderId = model.addFolder(name: "f", parentId: nil)
        let a = model.addLink(urlString: "https://a", title: "a", parentId: nil)
        let b = model.addLink(urlString: "https://b", title: "b", parentId: nil)
        let nested1 = model.addLink(urlString: "https://n1", title: "n1", parentId: folderId)
        let nested2 = model.addLink(urlString: "https://n2", title: "n2", parentId: folderId)

        // Reverse both levels.
        model.reorderNodesFromSync(sortOrders: [
            b: 0, folderId: 1, a: 2,
            nested2: 0, nested1: 1
        ])

        let topIds = model.workspaces[0].items.map(\.id)
        XCTAssertEqual(topIds, [b, folderId, a])
        if case .folder(let f) = model.workspaces[0].items.first(where: { $0.id == folderId })! {
            XCTAssertEqual(f.children.map(\.id), [nested2, nested1])
        }
    }

    // MARK: - deletes from sync

    func testDeleteNodeFromAnyWorkspace_removesAcrossWorkspaces() {
        // Add a node to a non-current workspace.
        let secondWsId = model.createWorkspace(name: "second", colorId: .ocean)
        // model.createWorkspace switches selection to the new one, so add there.
        let leafId = model.addLink(urlString: "https://x", title: "x", parentId: nil)

        // Switch back so currentWorkspace is no longer the one holding the leaf.
        model.selectWorkspace(id: model.workspaces[0].id)

        model.deleteNodeFromAnyWorkspace(id: leafId)

        // Look through all workspaces — should be gone.
        for ws in model.workspaces {
            XCTAssertNil(ws.items.first(where: { $0.id == leafId }))
        }
        _ = secondWsId
    }

    func testDeleteWorkspaceFromSync_preservesAtLeastOneWorkspace() {
        let onlyId = model.workspaces[0].id
        model.deleteWorkspaceFromSync(id: onlyId)

        XCTAssertEqual(model.workspaces.count, 1, "A fallback workspace must be created")
        XCTAssertNotEqual(model.workspaces[0].id, onlyId, "The deleted workspace is gone")
    }
}
