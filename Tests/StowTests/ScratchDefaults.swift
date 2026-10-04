import XCTest

extension XCTestCase {
    /// A throwaway UserDefaults stored in the temporary directory (a suite named by a
    /// path lives at that path), so test runs leave nothing in ~/Library/Preferences.
    func scratchDefaults() -> UserDefaults {
        let path = NSTemporaryDirectory() + "stow-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: path)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(atPath: path + ".plist")
        }
        return defaults
    }
}
