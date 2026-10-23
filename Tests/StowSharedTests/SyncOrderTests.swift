import CloudKit
import XCTest
@testable import StowShared

/// Sparse sort orders: a move rewrites only the items that moved, so two devices
/// reordering different items both keep their moves.
final class SyncOrderTests: XCTestCase {

    private let ids = (0..<5).map { _ in UUID() }

    private func spaced(_ list: [UUID]) -> [UUID: Int] {
        SyncOrder.assign(list, previous: [:])
    }

    private func changed(_ before: [UUID: Int], _ after: [UUID: Int]) -> Set<UUID> {
        Set(after.filter { before[$0.key] != $0.value }.map(\.key))
    }

    private func assertIncreasing(_ list: [UUID], _ orders: [UUID: Int], file: StaticString = #filePath, line: UInt = #line) {
        let values = list.map { orders[$0]! }
        XCTAssertEqual(values, values.sorted(), file: file, line: line)
        XCTAssertEqual(Set(values).count, values.count, "orders must be distinct", file: file, line: line)
    }

    func testAFreshListGetsDistinctIncreasingOrders() {
        let orders = spaced(ids)
        assertIncreasing(ids, orders)
    }

    func testAnUnchangedListKeepsEveryOrder() {
        let base = spaced(ids)
        XCTAssertEqual(SyncOrder.assign(ids, previous: base), base)
    }

    func testMovingOneItemRewritesOnlyThatItem() {
        let base = spaced(ids)
        let moved = [ids[0], ids[3], ids[1], ids[2], ids[4]]
        let after = SyncOrder.assign(moved, previous: base)
        assertIncreasing(moved, after)
        XCTAssertEqual(changed(base, after), [ids[3]])
    }

    func testMovingTheFirstItemToTheEndRewritesOnlyIt() {
        let base = spaced(ids)
        let moved = Array(ids.dropFirst()) + [ids[0]]
        let after = SyncOrder.assign(moved, previous: base)
        assertIncreasing(moved, after)
        XCTAssertEqual(changed(base, after), [ids[0]])
    }

    func testInsertingAnItemRewritesOnlyTheNewOne() {
        let base = spaced(ids)
        let fresh = UUID()
        let list = [ids[0], ids[1], fresh, ids[2], ids[3], ids[4]]
        let after = SyncOrder.assign(list, previous: base)
        assertIncreasing(list, after)
        XCTAssertEqual(changed(base, after), [fresh])
    }

    func testDenseOrdersFromOlderBuildsStillComeOutIncreasing() {
        let legacy = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let moved = [ids[0], ids[3], ids[1], ids[2], ids[4]]
        assertIncreasing(moved, SyncOrder.assign(moved, previous: legacy))
    }

    func testTwoDevicesMovingDifferentItemsBothKeepTheirMove() {
        let base = spaced(ids)
        // Mac A moves ids[4] to the front; Mac B moves ids[1] after ids[3].
        let onA = SyncOrder.assign([ids[4], ids[0], ids[1], ids[2], ids[3]], previous: base)
        let onB = SyncOrder.assign([ids[0], ids[2], ids[3], ids[1], ids[4]], previous: base)
        var server = base
        for (id, order) in onA where base[id] != order { server[id] = order }
        for (id, order) in onB where base[id] != order { server[id] = order }

        let merged = SyncOrder.arrange(ids, id: { $0 }, orders: server)
        XCTAssertEqual(merged, [ids[4], ids[0], ids[2], ids[3], ids[1]])
    }

    func testAFetchKeepsAnUnsentLocalMoveAndAppliesTheRemoteOne() {
        let base = spaced(ids)
        // This Mac moved ids[0] to the end but hasn't uploaded it; meanwhile another Mac
        // moved ids[3] to the front, and that record has just arrived.
        let local = [ids[1], ids[2], ids[3], ids[4], ids[0]]
        let remote = SyncOrder.assign([ids[3], ids[0], ids[1], ids[2], ids[4]], previous: base)
        var known = base
        known[ids[3]] = remote[ids[3]]

        let orders = SyncOrder.merge(levels: [local], known: known, fetched: [ids[3]: remote[ids[3]]!])
        XCTAssertEqual(SyncOrder.arrange(local, id: { $0 }, orders: orders), [ids[3], ids[1], ids[2], ids[4], ids[0]])
    }

    func testArrangeKeepsItemsWithoutAnOrderAfterTheirPredecessor() {
        let local = UUID()
        let orders: [UUID: Int] = [ids[0]: 30, ids[1]: 10, ids[2]: 20]
        let arranged = SyncOrder.arrange([ids[0], local, ids[1], ids[2]], id: { $0 }, orders: orders)
        XCTAssertEqual(arranged, [ids[1], ids[2], ids[0], local])
    }

    func testArrangeBreaksTiesById() {
        let (low, high) = ids[0].uuidString < ids[1].uuidString ? (ids[0], ids[1]) : (ids[1], ids[0])
        XCTAssertEqual(SyncOrder.arrange([high, low], id: { $0 }, orders: [high: 5, low: 5]), [low, high])
    }

    func testFlattenRewritesOnlyTheMovedNodesOrder() {
        let zone = CKRecordZone.ID(zoneName: "TestZone")
        let nodes = ids.map { Node.link(Link(id: $0, title: "t", url: "https://\($0).test", faviconPath: nil)) }
        let base = RecordConverter.flattenNodes(nodes: nodes, workspaceId: UUID(), zoneID: zone)
        let previous = Dictionary(uniqueKeysWithValues: base.map { ($1.id, $0[CKNodeFields.sortOrder] as! Int) })

        let movedNodes = [nodes[2], nodes[0], nodes[1], nodes[3], nodes[4]]
        let after = RecordConverter.flattenNodes(nodes: movedNodes, workspaceId: UUID(), zoneID: zone, previousSortOrders: previous)
        let afterOrders = Dictionary(uniqueKeysWithValues: after.map { ($1.id, $0[CKNodeFields.sortOrder] as! Int) })

        XCTAssertEqual(changed(previous, afterOrders), [ids[2]])
    }

    func testSyncReorderKeepsLocalOnlyNodesBesideTheirNeighbour() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stow-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: DataStore(baseDirectory: dir))
        let c = model.addLink(urlString: "https://c", title: "c", parentId: nil)
        let b = model.addLink(urlString: "https://b", title: "b", parentId: nil)
        let a = model.addLink(urlString: "https://a", title: "a", parentId: nil)
        let notYetUploaded = model.addLink(urlString: "https://new", title: "new", parentId: nil)
        XCTAssertEqual(model.workspaces[0].items.map(\.id), [c, b, a, notYetUploaded])

        // The server knows a, b and c with sparse orders and moves c to the front.
        model.reorderNodesFromSync(sortOrders: [c: 1 << 19, a: 1 << 20, b: 2 << 20])

        XCTAssertEqual(model.workspaces[0].items.map(\.id), [c, a, notYetUploaded, b])
    }
}
