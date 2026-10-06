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

    /// The browser Attached mode sits beside: the one last in front, else the system default.
    @MainActor
    static func attachTargetBundleId() -> String? {
        if let active = ActiveBrowserTracker.shared.lastActiveBundleId,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: active) != nil {
            return active
        }
        return defaultBrowserBundleId()
    }

    static func open(url: URL, bundleId targetBundleId: String? = nil, profile: String? = nil) {
        if let bundleId = targetBundleId ?? defaultBrowserBundleId(),
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

    static func isBrowser(_ bundleId: String) -> Bool {
        bundleId != Bundle.main.bundleIdentifier && installedBrowsers().contains { $0.bundleId == bundleId }
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

    static func isChromiumBased(_ bundleId: String) -> Bool {
        let chromiumBundleIds = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
        ]
        return chromiumBundleIds.contains(bundleId)
    }

    /// Where a Chromium browser keeps its profiles (each holds a `Bookmarks` file).
    static func chromiumSupportDirectory(_ bundleId: String) -> URL? {
        let dir: String
        switch bundleId {
        case "com.google.Chrome": dir = "Google/Chrome"
        case "com.google.Chrome.canary": dir = "Google/Chrome Canary"
        case "com.brave.Browser": dir = "BraveSoftware/Brave-Browser"
        case "com.microsoft.edgemac": dir = "Microsoft Edge"
        case "com.vivaldi.Vivaldi": dir = "Vivaldi"
        default: return nil
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dir)")
    }

    private static func chromiumProfiles(bundleId: String) -> [BrowserProfile] {
        guard let support = chromiumSupportDirectory(bundleId) else { return [] }
        let localStatePath = support.appendingPathComponent("Local State")

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
