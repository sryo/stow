import Foundation

/// The subset of NSUbiquitousKeyValueStore page-color sync uses, so tests can swap it.
public protocol PageColorKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: PageColorKeyValueStore {}

/// Page color is the one app preference that looks the same on every device. It's
/// mirrored to iCloud key-value storage under the same key StowTheme.preferredTint reads
/// locally. (Without the ubiquity-kvstore entitlement the store is inert and the
/// preference simply stays local.)
public final class PageColorSync {
    public static let key = "StowTintMode"

    private let store: PageColorKeyValueStore
    private let defaults: UserDefaults

    public init(store: PageColorKeyValueStore = NSUbiquitousKeyValueStore.default, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public func publish(_ tint: StowTheme.TintMode) {
        store.set(tint.rawValue, forKey: Self.key)
        store.synchronize()
    }

    /// Takes the value another device published, if any. Returns it when it was adopted.
    @discardableResult
    public func adoptRemote() -> StowTheme.TintMode? {
        guard let raw = store.string(forKey: Self.key), let tint = StowTheme.TintMode(rawValue: raw) else { return nil }
        guard defaults.string(forKey: Self.key) != raw else { return tint }
        defaults.set(raw, forKey: Self.key)
        return tint
    }
}
