import Foundation
import StowShared

/// The container the app, the share extension and the widget all read data.json from.
enum AppGroup {
    static let identifier = "group.com.stow.app"

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Stow")
    }

    /// Defaults every Stow process on this iPhone can read.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: identifier) ?? .standard

    static func makeStore() -> DataStore {
        DataStore(baseDirectory: containerURL)
    }

    /// Favicons, shared so the widget and the Live Activity draw what the app fetched.
    static var iconsDirectory: URL {
        makeStore().iconsDirectory()
    }
}
