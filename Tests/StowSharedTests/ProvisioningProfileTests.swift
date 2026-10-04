#if os(macOS)
import XCTest
@testable import StowShared

/// macOS keeps a bundle's profile at Contents/embedded.provisionprofile, not in Resources.
/// Looking in Resources kept iCloud sync off in every build, provisioned or not.
final class ProvisioningProfileTests: XCTestCase {
    private func makeBundle(profileAt relativePath: String?) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        if let relativePath {
            try Data("profile".utf8).write(to: app.appendingPathComponent(relativePath))
        }
        return app
    }

    func testFindsTheProfileWhereMacOSKeepsIt() throws {
        XCTAssertTrue(CloudSyncManager.hasProvisioningProfile(bundleURL: try makeBundle(profileAt: "Contents/embedded.provisionprofile")))
    }

    func testABundleWithoutAProfileHasNone() throws {
        XCTAssertFalse(CloudSyncManager.hasProvisioningProfile(bundleURL: try makeBundle(profileAt: nil)))
    }
}
#endif
