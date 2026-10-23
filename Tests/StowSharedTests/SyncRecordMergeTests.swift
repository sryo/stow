import CloudKit
import XCTest
@testable import StowShared

/// When an upload collides with a newer server copy, each side keeps the fields it
/// changed: a rename here and a colour change on another Mac both survive.
final class SyncRecordMergeTests: XCTestCase {

    private let zone = CKRecordZone.ID(zoneName: "TestZone")
    private let workspaceId = UUID()

    private func workspaceRecord(name: String, color: WorkspaceColorId) -> CKRecord {
        let ws = Workspace(id: workspaceId, name: name, colorId: color, items: [])
        return RecordConverter.workspaceToCKRecord(workspace: ws, sortOrder: 0, zoneID: zone)
    }

    private func linkRecord(_ id: UUID, title: String, url: String) -> CKRecord {
        RecordConverter.nodeToCKRecord(
            node: .link(Link(id: id, title: title, url: url, faviconPath: nil)),
            workspaceId: workspaceId, parentNodeId: nil, sortOrder: 0, zoneID: zone
        )
    }

    private func link(_ record: CKRecord) -> Link? {
        if case .link(let link) = RecordConverter.ckRecordToNode(record: record) { return link }
        return nil
    }

    func testARenameHereAndAColourChangeThereBothSurvive() {
        let base = workspaceRecord(name: "Work", color: .defaultColor())
        let ours = workspaceRecord(name: "Office", color: .defaultColor())
        let theirs = workspaceRecord(name: "Work", color: .ruby)

        let merged = RecordMerge.merge(base: base, ours: ours, theirs: theirs)
        let workspace = RecordConverter.ckRecordToWorkspace(record: merged)
        XCTAssertEqual(workspace?.name, "Office")
        XCTAssertEqual(workspace?.colorId, .ruby)
    }

    func testALinkRenamedHereAndRepointedThereKeepsBoth() {
        let id = UUID()
        let base = linkRecord(id, title: "Docs", url: "https://old.test")
        let ours = linkRecord(id, title: "Team docs", url: "https://old.test")
        let theirs = linkRecord(id, title: "Docs", url: "https://new.test")

        let merged = link(RecordMerge.merge(base: base, ours: ours, theirs: theirs))
        XCTAssertEqual(merged?.title, "Team docs")
        XCTAssertEqual(merged?.url, "https://new.test")
    }

    func testTheSameFieldChangedOnBothSidesKeepsThisMacsEdit() {
        let id = UUID()
        let base = linkRecord(id, title: "Docs", url: "https://a.test")
        let ours = linkRecord(id, title: "Mine", url: "https://a.test")
        let theirs = linkRecord(id, title: "Theirs", url: "https://a.test")

        XCTAssertEqual(link(RecordMerge.merge(base: base, ours: ours, theirs: theirs))?.title, "Mine")
    }

    func testWithoutAKnownBaseTheServerWins() {
        let id = UUID()
        let ours = linkRecord(id, title: "Mine", url: "https://a.test")
        let theirs = linkRecord(id, title: "Theirs", url: "https://b.test")

        let merged = link(RecordMerge.merge(base: nil, ours: ours, theirs: theirs))
        XCTAssertEqual(merged?.title, "Theirs")
        XCTAssertEqual(merged?.url, "https://b.test")
    }

    func testTheMergeIsBuiltOnTheServerCopy() {
        let base = workspaceRecord(name: "Work", color: .defaultColor())
        let ours = workspaceRecord(name: "Office", color: .defaultColor())
        let theirs = workspaceRecord(name: "Work", color: .ruby)
        XCTAssertTrue(RecordMerge.merge(base: base, ours: ours, theirs: theirs) === theirs,
                      "uploading the merge needs the server copy's change tag")
    }
}
