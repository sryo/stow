import XCTest
@testable import StowShared

/// Where favicons live on disk and how other processes (the iPhone widget and Live
/// Activity) find them by file name.
final class FaviconStorageTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-favstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func link(_ url: String, faviconPath: String? = nil) -> Link {
        Link(id: UUID(), title: "t", url: url, faviconPath: faviconPath)
    }

    func testFileNameIsTheLowercasedHostWithPortColonsReplaced() {
        XCTAssertEqual(FaviconStorage.fileName(forHost: "Example.COM"), "example.com.ico")
        XCTAssertEqual(FaviconStorage.fileName(forHost: "localhost:8080"), "localhost_8080.ico")
    }

    func testFileNameForALinkPrefersTheHostFileWhenItExists() throws {
        let icons = try folder("Icons")
        try Data([1]).write(to: icons.appendingPathComponent("feedly.com.ico"))
        XCTAssertEqual(FaviconStorage.fileName(for: link("https://feedly.com/i/latest"), in: icons), "feedly.com.ico")
    }

    func testFileNameForALinkFallsBackToItsStoredPathsName() throws {
        let icons = try folder("Icons")
        try Data([1]).write(to: icons.appendingPathComponent("custom.png"))
        let stored = "/somewhere/else/Icons/custom.png"
        XCTAssertEqual(FaviconStorage.fileName(for: link("https://nofile.example", faviconPath: stored), in: icons), "custom.png")
    }

    func testFileNameForALinkIsNilWithoutAnIconOnDisk() throws {
        let icons = try folder("Icons")
        XCTAssertNil(FaviconStorage.fileName(for: link("https://feedly.com"), in: icons))
        XCTAssertNil(FaviconStorage.fileName(for: link("not a url"), in: icons))
    }

    func testMoveIconsMovesEveryFileAndKeepsExistingDestinationFiles() throws {
        let old = try folder("Private/Icons")
        let new = try folder("Group/Icons")
        try Data([1]).write(to: old.appendingPathComponent("a.com.ico"))
        try Data([2]).write(to: old.appendingPathComponent("b.com.ico"))
        try Data([9]).write(to: new.appendingPathComponent("b.com.ico"))

        let moved = FaviconStorage.moveIcons(from: old, to: new)

        XCTAssertEqual(moved, 1)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("a.com.ico")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("b.com.ico")), Data([9]), "newer copy wins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("a.com.ico").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("b.com.ico").path))
    }

    func testMoveIconsCreatesTheDestinationAndToleratesAMissingSource() throws {
        let old = try folder("Private/Icons")
        try Data([1]).write(to: old.appendingPathComponent("a.com.ico"))
        let new = root.appendingPathComponent("Group/Icons", isDirectory: true)

        XCTAssertEqual(FaviconStorage.moveIcons(from: old, to: new), 1)
        XCTAssertEqual(FaviconStorage.moveIcons(from: root.appendingPathComponent("nope"), to: new), 0)
        XCTAssertEqual(FaviconStorage.moveIcons(from: new, to: new), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("a.com.ico").path))
    }
}
