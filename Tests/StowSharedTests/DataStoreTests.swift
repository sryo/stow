import XCTest
@testable import StowShared

final class DataStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> DataStore {
        DataStore(baseDirectory: tempDir)
    }

    private func dataURL() -> URL {
        tempDir.appendingPathComponent("data.json")
    }

    private func preservedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix("data.json.corrupt-") }
    }

    func testLoad_freshDirectoryWritesDefaultState() {
        let state = makeStore().load()
        XCTAssertEqual(state.schemaVersion, DataStore.currentSchemaVersion)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataURL().path))
    }

    func testLoad_corruptJsonIsPreservedNotOverwritten() throws {
        try Data("{ this is not valid json".utf8).write(to: dataURL())

        let state = makeStore().load()

        XCTAssertEqual(state.workspaces.count, 1, "Should fall back to default state")
        let preserved = preservedFiles()
        XCTAssertEqual(preserved.count, 1, "Original corrupt file should be preserved")
        let preservedBytes = try Data(contentsOf: preserved[0])
        XCTAssertEqual(String(data: preservedBytes, encoding: .utf8), "{ this is not valid json")
    }

    func testLoad_truncatedJsonIsPreserved() throws {
        // Encode a real state then chop off the last byte.
        let encoder = JSONEncoder()
        let valid = try encoder.encode(DataStore.defaultState())
        try valid.dropLast().write(to: dataURL())

        _ = makeStore().load()

        XCTAssertEqual(preservedFiles().count, 1)
    }

    func testLoad_futureSchemaVersionIsRejectedWithoutClobber() throws {
        // Write a state claiming a higher schema version than this build knows.
        let futureJson = """
        {
          "schemaVersion": 999,
          "workspaces": [],
          "isSettingsSelected": false
        }
        """
        try Data(futureJson.utf8).write(to: dataURL())

        let state = makeStore().load()

        XCTAssertEqual(state.schemaVersion, DataStore.currentSchemaVersion)
        let preserved = preservedFiles()
        XCTAssertEqual(preserved.count, 1, "Future-schema file must be preserved")
        XCTAssertTrue(preserved[0].lastPathComponent.contains("futureSchema_v999"))
    }

    func testLoad_validV2RoundTrips() throws {
        let store = makeStore()
        let original = store.load()
        store.save(original)

        let reloaded = makeStore().load()
        XCTAssertEqual(reloaded.workspaces.first?.id, original.workspaces.first?.id)
        XCTAssertEqual(preservedFiles().count, 0, "Valid file should not be preserved as corrupt")
    }

    func testLoad_emptyFileIsPreservedAsCorrupt() throws {
        try Data().write(to: dataURL())
        _ = makeStore().load()
        XCTAssertEqual(preservedFiles().count, 1)
    }

    func testLoad_savesDefaultStateAfterCorruptRescue() throws {
        try Data("garbage".utf8).write(to: dataURL())

        _ = makeStore().load()

        // The new default state must be saved at the original path so the next save doesn't clobber the preserved copy.
        let saved = try Data(contentsOf: dataURL())
        XCTAssertNotEqual(String(data: saved, encoding: .utf8), "garbage")
        XCTAssertTrue(saved.count > 10)
    }
}
