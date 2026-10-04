import AppKit
import Foundation

public struct OpenTab: Equatable, Sendable {
    public let bundleId: String
    public let windowId: String
    public let tabIndex: Int  // 1-based, AppleScript convention
    public let url: URL
    public let title: String
}

/// Reads and focuses browser tabs via AppleScript. The only table of supported browsers:
/// OpenTabsMonitor, the Tabline and opening links all go through here.
///
/// Requires `NSAppleEventsUsageDescription` in Info.plist. macOS prompts the
/// user once per (Stow → target browser) pair the first time AppleScript
/// reaches each browser; if the user denies, the methods here return empty /
/// false and the caller should fall through to `BrowserManager.open`.
public enum BrowserTabService {

    // Keep in sync with BrowserManager.isChromiumBased — the second column is
    // the AppleScript display name (not stored elsewhere in StowCore).
    private static let chromiumBrowsers: [(bundleId: String, appName: String)] = [
        ("com.google.Chrome",        "Google Chrome"),
        ("com.google.Chrome.canary", "Google Chrome Canary"),
        ("com.brave.Browser",        "Brave Browser"),
        ("com.microsoft.edgemac",    "Microsoft Edge"),
        ("com.vivaldi.Vivaldi",      "Vivaldi"),
    ]

    // Arc ships its own AppleScript dictionary — same `tell application`/`window`
    // shape but the window id is a string UUID rather than an integer, and the
    // active tab is selected via `tell tab N to select` rather than `set active tab index`.
    private static let arcBundleId    = "company.thebrowser.Browser"
    private static let arcAppName     = "Arc"

    private static let safariBundleId = "com.apple.Safari"
    private static let safariAppName  = "Safari"

    static var supportedBundleIds: [String] { chromiumBrowsers.map(\.bundleId) + [arcBundleId, safariBundleId] }

    /// Whether any browser this service can script is running.
    static func anySupportedBrowserRunning() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return supportedBundleIds.contains { running.contains($0) }
    }

    /// NSAppleScript isn't safe to run from several threads at once, and the lookups here
    /// fan out across browsers, so every script runs under this lock.
    private static let scriptLock = NSLock()

    // MARK: - Public

    public static func listTabs() -> [OpenTab] {
        var tabs: [OpenTab] = []
        for bundleId in supportedBundleIds where BrowserManager.isRunning(bundleId: bundleId) {
            tabs.append(contentsOf: self.tabs(bundleId: bundleId))
        }
        return tabs
    }

    /// If `url` is open in any supported browser, focus that tab and return true.
    /// Returns false on miss or on focus failure — caller should fall through to
    /// `BrowserManager.open` in either case. Queries each running browser
    /// concurrently and returns on the first match; `cancelAll` only suppresses
    /// unstarted tasks (in-flight AppleScripts run to completion).
    /// When `onlyIn` is set, only that browser's tabs are considered, so opening a link
    /// never pulls the user out of the browser they're working in.
    public static func focusIfOpen(url: URL, onlyIn onlyBundleId: String? = nil) async -> Bool {
        let target = canonicalize(url)
        let allowed: (String) -> Bool = { onlyBundleId == nil || $0 == onlyBundleId }
        let match = await withTaskGroup(of: OpenTab?.self) { group -> OpenTab? in
            for bundleId in supportedBundleIds where allowed(bundleId) && BrowserManager.isRunning(bundleId: bundleId) {
                group.addTask { tabs(bundleId: bundleId).first { canonicalize($0.url) == target } }
            }
            for await result in group {
                if let hit = result {
                    group.cancelAll()
                    return hit
                }
            }
            return nil
        }
        guard let hit = match else { return false }
        return focus(tab: hit)
    }

    /// Snapshot of every open tab across every running browser, keyed by
    /// canonical URL (last writer wins on duplicates). For bulk lookups —
    /// queries each browser exactly once instead of per-URL fan-out.
    public static func tabsByCanonicalURL() async -> [String: OpenTab] {
        let lists = await withTaskGroup(of: [OpenTab].self) { group -> [[OpenTab]] in
            for bundleId in supportedBundleIds where BrowserManager.isRunning(bundleId: bundleId) {
                group.addTask { tabs(bundleId: bundleId) }
            }
            var collected: [[OpenTab]] = []
            for await list in group { collected.append(list) }
            return collected
        }
        var map: [String: OpenTab] = [:]
        for list in lists {
            for tab in list { map[canonicalize(tab.url)] = tab }
        }
        return map
    }

    /// URL and title of the active tab in the front window of `bundleId`'s browser.
    public static func frontTab(bundleId: String) -> (url: URL, title: String)? {
        let appName: String
        let titleKey: String
        if bundleId == safariBundleId {
            appName = safariAppName; titleKey = "name"
        } else if bundleId == arcBundleId {
            appName = arcAppName; titleKey = "title"
        } else if let entry = chromiumBrowsers.first(where: { $0.bundleId == bundleId }) {
            appName = entry.appName; titleKey = "title"
        } else {
            return nil
        }
        let tabExpr = bundleId == safariBundleId ? "current tab of front window" : "active tab of front window"
        let script = """
        set sep to character id 9
        tell application "\(appName)"
            set t to \(tabExpr)
            return (URL of t) & sep & (\(titleKey) of t)
        end tell
        """
        guard let output = runAppleScript(script) else { return nil }
        let cols = output.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = cols.first, let url = URL(string: String(first)), url.scheme != nil else { return nil }
        return (url, cols.count > 1 ? String(cols[1]) : url.host ?? url.absoluteString)
    }

    // MARK: - Per-browser tab listing

    /// The AppleScript that lists every tab of `bundleId`'s browser as
    /// `windowId \t tabIndex \t url \t title` rows, or nil for an unsupported browser.
    static func tabListScript(bundleId: String) -> String? {
        let appName: String
        // Safari tabs expose `name` rather than `title`.
        let titleKey = bundleId == safariBundleId ? "name" : "title"
        if bundleId == safariBundleId {
            appName = safariAppName
        } else if bundleId == arcBundleId {
            appName = arcAppName
        } else if let entry = chromiumBrowsers.first(where: { $0.bundleId == bundleId }) {
            appName = entry.appName
        } else {
            return nil
        }
        return """
        set sep to character id 9
        tell application "\(appName)"
            set output to ""
            repeat with w in windows
                set wid to id of w as string
                -- One request per property for the whole window: fast with hundreds of tabs, and
                -- Arc can't hold a tab in a variable. A tab with no URL (Arc's empty and
                -- special tabs) fails only its own row instead of the whole listing.
                set urls to URL of tabs of w
                set titles to \(titleKey) of tabs of w
                repeat with i from 1 to (count of urls)
                    try
                        set output to output & wid & sep & i & sep & (item i of urls) & sep & (item i of titles) & linefeed
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    }

    private static func tabs(bundleId: String) -> [OpenTab] {
        guard let script = tabListScript(bundleId: bundleId) else { return [] }
        return parseRows(runAppleScript(script), bundleId: bundleId)
    }

    // MARK: - Focus

    static func focus(tab: OpenTab) -> Bool {
        guard let script = focusScript(tab: tab) else { return false }
        // Focus scripts return no value, so success means "no error", not "some output".
        return runAppleScriptSucceeded(script)
    }

    /// Selects the tab, then raises its window and activates the browser.
    static func focusScript(tab: OpenTab) -> String? {
        let script: String
        switch tab.bundleId {
        case safariBundleId:
            script = """
            tell application "Safari"
                tell window id \(tab.windowId)
                    set current tab to tab \(tab.tabIndex)
                    -- Best effort: Arc rejects this while another app is in front.
                    try
                        set index to 1
                    end try
                end tell
                activate
            end tell
            """
        case arcBundleId:
            // Arc's window id is a UUID string; quote it.
            script = """
            tell application "Arc"
                tell window id "\(tab.windowId)"
                    tell tab \(tab.tabIndex) to select
                    -- Best effort: Arc rejects this while another app is in front.
                    try
                        set index to 1
                    end try
                end tell
                activate
            end tell
            """
        default:
            guard let appName = chromiumBrowsers.first(where: { $0.bundleId == tab.bundleId })?.appName else { return nil }
            script = """
            tell application "\(appName)"
                tell window id \(tab.windowId)
                    set active tab index to \(tab.tabIndex)
                    -- Best effort: Arc rejects this while another app is in front.
                    try
                        set index to 1
                    end try
                end tell
                activate
            end tell
            """
        }
        return script
    }

    // MARK: - AppleScript runner

    private static func runAppleScriptSucceeded(_ source: String) -> Bool {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        guard let script = NSAppleScript(source: source) else { return false }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return err == nil
    }

    private static func runAppleScript(_ source: String) -> String? {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        guard let script = NSAppleScript(source: source) else { return nil }
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if err != nil { return nil }
        return result.stringValue
    }

    // MARK: - Parsing (internal for tests)

    static func parseRows(_ output: String?, bundleId: String) -> [OpenTab] {
        guard let output = output else { return [] }
        var tabs: [OpenTab] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // maxSplits: 3 lets the title column absorb embedded tabs — page titles
            // are arbitrary user/site strings. URL is assumed tab-free per RFC 3986.
            let cols = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard cols.count == 4,
                  let tabIndex = Int(cols[1]),
                  let url = URL(string: String(cols[2])) else { continue }
            tabs.append(OpenTab(
                bundleId: bundleId,
                windowId: String(cols[0]),
                tabIndex: tabIndex,
                url: url,
                title: String(cols[3])
            ))
        }
        return tabs
    }

    // MARK: - URL canonicalization

    /// Forwards to `URLCanonical.key`, the shared definition of "the same page".
    static func canonicalize(_ url: URL) -> String {
        URLCanonical.key(url)
    }
}
