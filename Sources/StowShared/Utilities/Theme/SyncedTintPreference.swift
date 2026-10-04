import Foundation

/// The two stores page color lives in: this device's defaults and iCloud key-value storage.
public protocol StringKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension UserDefaults: StringKeyValueStore {
    public func setString(_ value: String, forKey key: String) {
        set(value, forKey: key)
    }
}

extension NSUbiquitousKeyValueStore: StringKeyValueStore {
    public func setString(_ value: String, forKey key: String) {
        set(value as String?, forKey: key)
    }
}

/// Page color (Full / Soft / None) is the one app preference that follows the user to
/// every device. The local copy stays under the key `StowTheme.preferredTint` already
/// reads, and the same key in iCloud key-value storage carries it between the Mac and
/// the iPhone. Both apps must share one KVS identifier (`$(TeamIdentifierPrefix)com.stow.app`).
@MainActor
public final class SyncedTintPreference {
    public static let key = "StowTintMode"
    /// Posted on the preference's notification center after the value changes, locally
    /// or from another device.
    public static let didChangeNotification = Notification.Name("StowSyncedTintDidChange")

    public static let shared = SyncedTintPreference(
        local: UserDefaults.standard,
        cloud: NSUbiquitousKeyValueStore.default,
        notificationCenter: .default
    )

    private let local: StringKeyValueStore
    private let cloud: StringKeyValueStore
    private let notificationCenter: NotificationCenter
    private var externalChangeObserver: NSObjectProtocol?

    public init(local: StringKeyValueStore, cloud: StringKeyValueStore, notificationCenter: NotificationCenter = .default) {
        self.local = local
        self.cloud = cloud
        self.notificationCenter = notificationCenter
    }

    public var tint: StowTheme.TintMode {
        Self.decode(local.string(forKey: Self.key)) ?? .full
    }

    public func set(_ tint: StowTheme.TintMode) {
        local.setString(tint.rawValue, forKey: Self.key)
        cloud.setString(tint.rawValue, forKey: Self.key)
        cloud.synchronize()
        postChange()
    }

    /// Reconciles with iCloud once and then follows changes made on other devices.
    /// iCloud wins when it holds a value; otherwise this device's choice is published.
    public func start() {
        if externalChangeObserver == nil, let store = cloud as? NSUbiquitousKeyValueStore {
            externalChangeObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { [weak self] note in
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
                MainActor.assumeIsolated { self?.handleExternalChange(changedKeys: keys) }
            }
        }
        cloud.synchronize()

        if let remote = Self.decode(cloud.string(forKey: Self.key)) {
            if remote != Self.decode(local.string(forKey: Self.key)) {
                local.setString(remote.rawValue, forKey: Self.key)
                postChange()
            }
        } else if let mine = Self.decode(local.string(forKey: Self.key)) {
            cloud.setString(mine.rawValue, forKey: Self.key)
            cloud.synchronize()
        }
    }

    public func handleExternalChange(changedKeys: [String]) {
        guard changedKeys.contains(Self.key),
              let remote = Self.decode(cloud.string(forKey: Self.key)),
              remote != Self.decode(local.string(forKey: Self.key))
        else { return }
        local.setString(remote.rawValue, forKey: Self.key)
        postChange()
    }

    private func postChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private static func decode(_ raw: String?) -> StowTheme.TintMode? {
        raw.flatMap(StowTheme.TintMode.init(rawValue:))
    }
}
