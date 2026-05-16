import AppKit
import Foundation

public struct OpenTab: Equatable, Sendable {
    public let bundleId: String
    public let windowId: String
    public let tabIndex: Int  // 1-based, AppleScript convention
    public let url: URL
    public let title: String
}

/// Reads and focuses browser tabs via AppleScript.
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

    // MARK: - Public

    public static func listTabs() -> [OpenTab] {
        var tabs: [OpenTab] = []
        for entry in chromiumBrowsers where BrowserManager.isRunning(bundleId: entry.bundleId) {
            tabs.append(contentsOf: chromiumTabs(appName: entry.appName, bundleId: entry.bundleId))
        }
        if BrowserManager.isRunning(bundleId: arcBundleId) {
            tabs.append(contentsOf: arcTabs())
        }
        if BrowserManager.isRunning(bundleId: safariBundleId) {
            tabs.append(contentsOf: safariTabs())
        }
        return tabs
    }

    /// If `url` is open in any supported browser, focus that tab and return true.
    /// Returns false on miss or on focus failure — caller should fall through to
    /// `BrowserManager.open` in either case. Queries each running browser
    /// concurrently and returns on the first match; `cancelAll` only suppresses
    /// unstarted tasks (in-flight AppleScripts run to completion).
    public static func focusIfOpen(url: URL) async -> Bool {
        let target = canonicalize(url)
        let match = await withTaskGroup(of: OpenTab?.self) { group -> OpenTab? in
            for entry in chromiumBrowsers where BrowserManager.isRunning(bundleId: entry.bundleId) {
                group.addTask { chromiumTabs(appName: entry.appName, bundleId: entry.bundleId).first { canonicalize($0.url) == target } }
            }
            if BrowserManager.isRunning(bundleId: arcBundleId) {
                group.addTask { arcTabs().first { canonicalize($0.url) == target } }
            }
            if BrowserManager.isRunning(bundleId: safariBundleId) {
                group.addTask { safariTabs().first { canonicalize($0.url) == target } }
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
            for entry in chromiumBrowsers where BrowserManager.isRunning(bundleId: entry.bundleId) {
                group.addTask { chromiumTabs(appName: entry.appName, bundleId: entry.bundleId) }
            }
            if BrowserManager.isRunning(bundleId: arcBundleId) {
                group.addTask { arcTabs() }
            }
            if BrowserManager.isRunning(bundleId: safariBundleId) {
                group.addTask { safariTabs() }
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

    // MARK: - Per-browser tab listing

    private static func chromiumTabs(appName: String, bundleId: String) -> [OpenTab] {
        let script = """
        tell application "\(appName)"
            set output to ""
            repeat with w in windows
                set wid to id of w as string
                set tabList to tabs of w
                repeat with i from 1 to (count of tabList)
                    set t to item i of tabList
                    set output to output & wid & tab & i & tab & (URL of t) & tab & (title of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
        return parseRows(runAppleScript(script), bundleId: bundleId)
    }

    private static func arcTabs() -> [OpenTab] {
        let script = """
        tell application "Arc"
            set output to ""
            repeat with w in windows
                set wid to id of w as string
                repeat with i from 1 to (count of tabs of w)
                    set t to tab i of w
                    set output to output & wid & tab & i & tab & (URL of t) & tab & (title of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
        return parseRows(runAppleScript(script), bundleId: arcBundleId)
    }

    private static func safariTabs() -> [OpenTab] {
        // Safari tabs expose `name` rather than `title`.
        let script = """
        tell application "Safari"
            set output to ""
            repeat with w in windows
                set wid to id of w as string
                repeat with i from 1 to (count of tabs of w)
                    set t to tab i of w
                    set output to output & wid & tab & i & tab & (URL of t) & tab & (name of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
        return parseRows(runAppleScript(script), bundleId: safariBundleId)
    }

    // MARK: - Focus

    static func focus(tab: OpenTab) -> Bool {
        let script: String
        switch tab.bundleId {
        case safariBundleId:
            script = """
            tell application "Safari"
                tell window id \(tab.windowId)
                    set current tab to tab \(tab.tabIndex)
                    set index to 1
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
                    set index to 1
                end tell
                activate
            end tell
            """
        default:
            guard let appName = chromiumBrowsers.first(where: { $0.bundleId == tab.bundleId })?.appName else { return false }
            script = """
            tell application "\(appName)"
                tell window id \(tab.windowId)
                    set active tab index to \(tab.tabIndex)
                    set index to 1
                end tell
                activate
            end tell
            """
        }
        return runAppleScript(script) != nil
    }

    // MARK: - AppleScript runner

    private static func runAppleScript(_ source: String) -> String? {
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

    // MARK: - URL canonicalization (internal for tests)

    /// Canonical form used for tab-matching. Lowercases scheme + host, strips
    /// the fragment, normalizes empty root path. Query string is preserved —
    /// many SPAs encode page identity in `?id=`.
    static func canonicalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let _ = components.scheme else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.string ?? url.absoluteString.lowercased()
    }
}
