import XCTest
import CloudKit
@testable import StowShared

/// CKRecord round-trip coverage for RecordConverter — the serialization seam
/// between the local model and CloudKit. CloudSyncMergeTests exercises the
/// model entry points with Node fixtures; these tests verify that what goes
/// into a CKRecord comes back out identical, including the encoding edge
/// cases (emoji, long values, nil optionals, archived flags).
final class RecordConverterTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "TestZone")
    private let workspaceId = UUID()

    private func roundTrip(_ node: Node, parentNodeId: UUID? = nil, sortOrder: Int = 0) -> Node? {
        let record = RecordConverter.nodeToCKRecord(
            node: node,
            workspaceId: workspaceId,
            parentNodeId: parentNodeId,
            sortOrder: sortOrder,
            zoneID: zoneID
        )
        return RecordConverter.ckRecordToNode(record: record)
    }

    // MARK: - Workspace

    func testWorkspaceRoundTrip() {
        let workspace = Workspace(
            id: UUID(),
            name: "Work 🚀 Projects",
            colorId: .ocean,
            items: [],
            browserProfiles: ["com.google.Chrome": "Profile 1", "org.mozilla.firefox": "dev-edition"]
        )
        let record = RecordConverter.workspaceToCKRecord(workspace: workspace, sortOrder: 3, zoneID: zoneID)
        let decoded = RecordConverter.ckRecordToWorkspace(record: record)

        XCTAssertEqual(decoded?.id, workspace.id)
        XCTAssertEqual(decoded?.name, workspace.name)
        XCTAssertEqual(decoded?.colorId, workspace.colorId)
        XCTAssertEqual(decoded?.browserProfiles, workspace.browserProfiles)
        XCTAssertEqual(record[CKWorkspaceFields.sortOrder] as? Int, 3)
        XCTAssertEqual(decoded?.items, [], "Items travel as separate Node records")
    }

    func testWorkspaceRoundTrip_customColor() {
        let workspace = Workspace(id: UUID(), name: "w", colorId: .custom("#AABBCC"), items: [])
        let record = RecordConverter.workspaceToCKRecord(workspace: workspace, sortOrder: 0, zoneID: zoneID)
        XCTAssertEqual(RecordConverter.ckRecordToWorkspace(record: record)?.colorId, .custom("#AABBCC"))
    }

    func testWorkspaceDecode_rejectsWrongRecordType() {
        let node = Node.link(Link(id: UUID(), title: "t", url: "https://x.test", faviconPath: nil))
        let record = RecordConverter.nodeToCKRecord(node: node, workspaceId: workspaceId, parentNodeId: nil, sortOrder: 0, zoneID: zoneID)
        XCTAssertNil(RecordConverter.ckRecordToWorkspace(record: record))
    }

    // MARK: - Link

    func testLinkRoundTrip() {
        let longURL = "https://example.test/path?" + Array(repeating: "k=v", count: 500).joined(separator: "&")
        let link = Link(id: UUID(), title: "Café ☕️ — notes", url: longURL, faviconPath: "Icons/abc.png", isArchived: true)
        XCTAssertEqual(roundTrip(.link(link)), .link(link))
    }

    func testLinkRoundTrip_nilFavicon() {
        let link = Link(id: UUID(), title: "t", url: "https://x.test", faviconPath: nil)
        XCTAssertEqual(roundTrip(.link(link)), .link(link))
    }

    // MARK: - Folder

    func testFolderRoundTrip_preservesMetadataAndDropsChildren() {
        let child = Node.link(Link(id: UUID(), title: "c", url: "https://c.test", faviconPath: nil))
        let folder = Folder(id: UUID(), name: "📁 Projekte", children: [child], isExpanded: false, isArchived: true)
        guard case .folder(let decoded)? = roundTrip(.folder(folder)) else {
            XCTFail("Expected folder"); return
        }
        XCTAssertEqual(decoded.id, folder.id)
        XCTAssertEqual(decoded.name, folder.name)
        XCTAssertEqual(decoded.isExpanded, false)
        XCTAssertEqual(decoded.isArchived, true)
        XCTAssertEqual(decoded.children, [], "Children travel as separate Node records")
    }

    // MARK: - Task

    func testTaskRoundTrip() {
        let task = TaskItem(
            id: UUID(),
            title: "Ship it ✅",
            isCompleted: true,
            dueDate: Date(timeIntervalSinceReferenceDate: 700_000_000),
            notes: "line one\nline two — ümlaut",
            createdAt: Date(timeIntervalSinceReferenceDate: 650_000_000),
            isArchived: true
        )
        XCTAssertEqual(roundTrip(.task(task)), .task(task))
    }

    func testTaskRoundTrip_nilOptionals() {
        let task = TaskItem(id: UUID(), title: "t", isCompleted: false, dueDate: nil, notes: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(roundTrip(.task(task)), .task(task))
    }

    // MARK: - Snippet

    func testSnippetRoundTrip() {
        let snippet = Snippet(
            id: UUID(),
            title: "greet.swift",
            content: "let s = \"héllo \\(name) 👋\"\n// \"quotes\" & <tags>",
            language: "swift",
            createdAt: Date(timeIntervalSinceReferenceDate: 600_000_000)
        )
        XCTAssertEqual(roundTrip(.snippet(snippet)), .snippet(snippet))
    }

    func testSnippetRoundTrip_nilLanguage() {
        let snippet = Snippet(id: UUID(), title: "t", content: "c", language: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(roundTrip(.snippet(snippet)), .snippet(snippet))
    }

    // MARK: - Malformed records

    func testNodeDecode_rejectsWrongRecordType() {
        let workspace = Workspace(id: UUID(), name: "w", colorId: .ocean, items: [])
        let record = RecordConverter.workspaceToCKRecord(workspace: workspace, sortOrder: 0, zoneID: zoneID)
        XCTAssertNil(RecordConverter.ckRecordToNode(record: record))
    }

    func testNodeDecode_rejectsMissingDataJSON() {
        let record = CKRecord(recordType: CKRecordTypes.node, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record[CKNodeFields.type] = "link" as CKRecordValue
        XCTAssertNil(RecordConverter.ckRecordToNode(record: record))
    }

    func testNodeDecode_rejectsUnknownType() {
        let record = CKRecord(recordType: CKRecordTypes.node, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record[CKNodeFields.type] = "playlist" as CKRecordValue
        record[CKNodeFields.dataJSON] = "{}" as CKRecordValue
        XCTAssertNil(RecordConverter.ckRecordToNode(record: record))
    }

    // MARK: - Tree flatten/rebuild

    func testFlattenAndRebuild_restoresNestedTreeInOrder() {
        let leafA = Node.link(Link(id: UUID(), title: "a", url: "https://a.test", faviconPath: nil))
        let leafB = Node.task(TaskItem(id: UUID(), title: "b", isCompleted: false, dueDate: nil, notes: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0)))
        let innerFolder = Node.folder(Folder(id: UUID(), name: "inner", children: [leafB], isExpanded: true))
        let outerFolder = Node.folder(Folder(id: UUID(), name: "outer", children: [leafA, innerFolder], isExpanded: false))
        let topSnippet = Node.snippet(Snippet(id: UUID(), title: "s", content: "c", language: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0)))
        let tree = [outerFolder, topSnippet]

        let flat = RecordConverter.flattenNodes(nodes: tree, workspaceId: workspaceId, zoneID: zoneID)
        XCTAssertEqual(flat.count, 5)

        // Decode through CKRecord (as a real fetch would) before rebuilding.
        let decodedFlat: [(record: CKRecord, node: Node)] = flat.compactMap { record, _ in
            RecordConverter.ckRecordToNode(record: record).map { (record: record, node: $0) }
        }
        XCTAssertEqual(decodedFlat.count, 5)

        let rebuilt = RecordConverter.buildNodeTree(flatNodes: decodedFlat)
        XCTAssertEqual(rebuilt, tree)
    }

    func testBuildNodeTree_sortsBySortOrderRegardlessOfArrivalOrder() {
        let first = Node.link(Link(id: UUID(), title: "first", url: "https://1.test", faviconPath: nil))
        let second = Node.link(Link(id: UUID(), title: "second", url: "https://2.test", faviconPath: nil))
        let third = Node.link(Link(id: UUID(), title: "third", url: "https://3.test", faviconPath: nil))
        let tree = [first, second, third]

        let flat = RecordConverter.flattenNodes(nodes: tree, workspaceId: workspaceId, zoneID: zoneID)
        let shuffled = [flat[2], flat[0], flat[1]].map { (record: $0.0, node: $0.1) }

        XCTAssertEqual(RecordConverter.buildNodeTree(flatNodes: shuffled), tree)
    }
}
