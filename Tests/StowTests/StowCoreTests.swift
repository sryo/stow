// Placeholder for macOS-specific tests.
// Base class tests are currently skipped due to Swift 6 concurrency requirements with XCTest.
import XCTest
@testable import StowCore

final class StowCoreTests: XCTestCase {
    func testStowCoreReExportsStowShared() {
        // Verify that StowCore re-exports StowShared types
        let _: AppState.Type = AppState.self
        let _: Workspace.Type = Workspace.self
        let _: Node.Type = Node.self
    }
}
