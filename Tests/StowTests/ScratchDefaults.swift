import XCTest

extension XCTestCase {
    /// A throwaway UserDefaults suite, removed (with its plist) when the test ends.
    func scratchDefaults() -> UserDefaults {
        let suite = "stow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        return defaults
    }
}
