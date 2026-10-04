import AppKit

/// Where a workspace's links open on this Mac: a browser and, optionally, one of its
/// profiles, picked as one value. No value means "Browser I'm using".
struct OpensIn: Codable, Equatable {
    var bundleId: String
    /// The profile's folder name (Chrome's "Profile 1", Firefox's profile path).
    var profile: String?

    static let browserImUsing = "Browser I’m using"

    static func label(browserName: String, profileName: String?) -> String {
        guard let profileName, !profileName.isEmpty else { return browserName }
        return "\(browserName) · \(profileName)"
    }

    /// "Google Chrome" reads as "Chrome" in a chip.
    static func shortName(_ name: String) -> String {
        for vendor in ["Google ", "Microsoft ", "Mozilla "] where name.hasPrefix(vendor) {
            return String(name.dropFirst(vendor.count))
        }
        return name
    }
}

/// The per-Mac map of workspace → OpensIn. Profile folders only exist on the Mac that
/// made them, so this never syncs.
struct OpensInStore {
    static let key = "workspaceOpensIn"
    static let migratedKey = "workspaceOpensInMigrated"

    var defaults: UserDefaults = .standard

    private var all: [String: OpensIn] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: OpensIn].self, from: data)) ?? [:]
    }

    func choice(for id: UUID) -> OpensIn? {
        all[id.uuidString]
    }

    func set(_ choice: OpensIn?, for id: UUID) {
        var map = all
        map[id.uuidString] = choice
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: .workspaceOpensInChanged, object: nil, userInfo: ["id": id])
    }

    /// Once per Mac: someone who pinned a browser globally gets it on every workspace
    /// (with that workspace's profile for it, if any); otherwise a workspace that had a
    /// profile opens in that profile's browser.
    func migrateIfNeeded(workspaces: [Workspace]) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        let pinned = (defaults.object(forKey: UserDefaultsKeys.openLinksInActiveBrowser) as? Bool) == false
            ? defaults.string(forKey: UserDefaultsKeys.defaultBrowserBundleId) : nil
        var map = all
        for workspace in workspaces where map[workspace.id.uuidString] == nil {
            if let pinned {
                map[workspace.id.uuidString] = OpensIn(bundleId: pinned, profile: workspace.browserProfiles[pinned])
            } else if let (bundleId, profile) = workspace.browserProfiles.sorted(by: { $0.key < $1.key }).first {
                map[workspace.id.uuidString] = OpensIn(bundleId: bundleId, profile: profile)
            }
        }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.key) }
    }
}

/// The browser and profile for opening a link, and whether to switch to an open tab first. Every place that opens
/// a link (click, Open all, Open in, the Tabline) resolves it here.
struct LinkTarget: Equatable {
    var bundleId: String?
    var profile: String?
    /// Switch to the link's tab if it's already open, in whichever browser has it (that's
    /// what the open-tab dot promises). False opens a fresh tab, which Option asks for.
    var focusesOpenTab = true

    static func resolve(choice: OpensIn?, activeBrowser: String?, systemDefault: String?,
                        isInstalled: (String) -> Bool, forceNewTab: Bool) -> LinkTarget {
        if let choice, isInstalled(choice.bundleId) {
            return LinkTarget(bundleId: choice.bundleId, profile: choice.profile, focusesOpenTab: !forceNewTab)
        }
        let active = activeBrowser.flatMap { isInstalled($0) ? $0 : nil }
        let bundleId = active ?? systemDefault
        return LinkTarget(bundleId: bundleId, profile: nil, focusesOpenTab: !forceNewTab)
    }

    /// Resolves against this Mac: the workspace's stored choice, the browser last in
    /// front, and the system default.
    @MainActor
    static func forWorkspace(_ id: UUID?, forceNewTab: Bool = NSEvent.modifierFlags.contains(.option)) -> LinkTarget {
        resolve(choice: id.flatMap { OpensInStore().choice(for: $0) },
                activeBrowser: ActiveBrowserTracker.shared.lastActiveBundleId,
                systemDefault: BrowserManager.defaultBrowserBundleId(),
                isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                forceNewTab: forceNewTab)
    }
}

extension Notification.Name {
    static let workspaceOpensInChanged = Notification.Name("StowWorkspaceOpensInChanged")
}
