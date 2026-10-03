import AppKit

/// Remembers the browser the user was last working in, so links open there instead
/// of always in one fixed browser.
@MainActor
final class ActiveBrowserTracker {
    static let shared = ActiveBrowserTracker()

    private static let storageKey = "lastActiveBrowserBundleId"
    private var browserIds: Set<String> = []
    private var observer: NSObjectProtocol?

    /// The browser that was frontmost most recently, persisted across launches.
    private(set) var lastActiveBundleId: String? {
        get { UserDefaults.standard.string(forKey: Self.storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    private init() {}

    func start() {
        guard observer == nil else { return }
        refreshInstalledBrowsers()
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { record(front) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let id = app?.bundleIdentifier else { return }
                self?.record(id)
            }
        }
    }

    private func record(_ bundleId: String) {
        if !browserIds.contains(bundleId) {
            // A browser installed after launch: refresh once before deciding.
            refreshInstalledBrowsers()
        }
        if browserIds.contains(bundleId) { lastActiveBundleId = bundleId }
    }

    private func refreshInstalledBrowsers() {
        browserIds = Set(BrowserManager.installedBrowsers().map(\.bundleId))
        browserIds.remove(Bundle.main.bundleIdentifier ?? "")
    }
}
