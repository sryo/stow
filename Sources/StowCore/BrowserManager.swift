import AppKit

struct BrowserInfo: Equatable {
    let bundleId: String
    let name: String
    let icon: NSImage?
}

struct BrowserProfile: Sendable {
    let directoryName: String
    let displayName: String
}

enum BrowserManager {
    static func installedBrowsers() -> [BrowserInfo] {
        guard let probeURL = URL(string: "http://example.com") else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        var seen: Set<String> = []
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url) else { return nil }
            guard let bundleId = bundle.bundleIdentifier else { return nil }
            if seen.contains(bundleId) { return nil }
            seen.insert(bundleId)
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleId
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return BrowserInfo(bundleId: bundleId, name: name, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultBrowserBundleId() -> String? {
        guard let probeURL = URL(string: "http://example.com") else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func resolveDefaultBrowserBundleId() -> String? {
        if let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultBrowserBundleId) {
            return stored
        }
        return defaultBrowserBundleId()
    }

    static var opensInActiveBrowser: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.openLinksInActiveBrowser) as? Bool ?? true
    }

    /// The browser a link should open in: the one the user was last working in, or the
    /// chosen default when that preference is off or no browser has been used yet.
    @MainActor
    static func linkTargetBundleId() -> String? {
        if opensInActiveBrowser, let active = ActiveBrowserTracker.shared.lastActiveBundleId,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: active) != nil {
            return active
        }
        return resolveDefaultBrowserBundleId()
    }

    static func open(url: URL, bundleId targetBundleId: String? = nil, profile: String? = nil) {
        if let bundleId = targetBundleId ?? resolveDefaultBrowserBundleId(),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let configuration = NSWorkspace.OpenConfiguration()
            if let profile = profile {
                if isChromiumBased(bundleId) {
                    configuration.arguments = ["--profile-directory=\(profile)"]
                } else if bundleId == "org.mozilla.firefox" {
                    configuration.arguments = ["-P", profile]
                }
            }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func isRunning(bundleId: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    static func frontmostApp() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Browser Profiles

    static func profiles(for bundleId: String) -> [BrowserProfile] {
        if isChromiumBased(bundleId) {
            return chromiumProfiles(bundleId: bundleId)
        } else if bundleId == "org.mozilla.firefox" {
            return firefoxProfiles()
        }
        return []
    }

    static func supportsProfiles(_ bundleId: String) -> Bool {
        return isChromiumBased(bundleId) || bundleId == "org.mozilla.firefox"
    }

    private static func isChromiumBased(_ bundleId: String) -> Bool {
        let chromiumBundleIds = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
        ]
        return chromiumBundleIds.contains(bundleId)
    }

    private static func chromiumProfiles(bundleId: String) -> [BrowserProfile] {
        let appSupportDir: String
        switch bundleId {
        case "com.google.Chrome":
            appSupportDir = "Google/Chrome"
        case "com.google.Chrome.canary":
            appSupportDir = "Google/Chrome Canary"
        case "com.brave.Browser":
            appSupportDir = "BraveSoftware/Brave-Browser"
        case "com.microsoft.edgemac":
            appSupportDir = "Microsoft Edge"
        case "com.vivaldi.Vivaldi":
            appSupportDir = "Vivaldi"
        default:
            return []
        }

        let localStatePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appSupportDir)/Local State")

        guard let data = try? Data(contentsOf: localStatePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileInfo = json["profile"] as? [String: Any],
              let infoCache = profileInfo["info_cache"] as? [String: Any] else {
            return []
        }

        return infoCache.compactMap { dirName, value in
            guard let info = value as? [String: Any] else { return nil }
            let displayName = info["name"] as? String ?? dirName
            return BrowserProfile(directoryName: dirName, displayName: displayName)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func firefoxProfiles() -> [BrowserProfile] {
        let profilesIniPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/profiles.ini")

        guard let content = try? String(contentsOf: profilesIniPath, encoding: .utf8) else { return [] }

        var profiles: [BrowserProfile] = []
        var currentName: String?
        var currentPath: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[Profile") {
                if let name = currentName, let path = currentPath {
                    profiles.append(BrowserProfile(directoryName: path, displayName: name))
                }
                currentName = nil
                currentPath = nil
            } else if trimmed.hasPrefix("Name=") {
                currentName = String(trimmed.dropFirst(5))
            } else if trimmed.hasPrefix("Path=") {
                currentPath = String(trimmed.dropFirst(5))
            }
        }

        // Don't forget the last profile
        if let name = currentName, let path = currentPath {
            profiles.append(BrowserProfile(directoryName: path, displayName: name))
        }

        return profiles
    }
}
