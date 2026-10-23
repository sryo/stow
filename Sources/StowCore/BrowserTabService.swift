import AppKit
import Foundation
import ScriptingBridge

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

    /// If `url` is open in any supported browser, focus that tab and return true. The tab
    /// is the best `URLMatch`: the same page, else the same page with changed view state.
    /// Returns false on miss or on focus failure — caller should fall through to
    /// `BrowserManager.open` in either case. Queries each running browser
    /// concurrently and returns on the first match; `cancelAll` only suppresses
    /// unstarted tasks (in-flight AppleScripts run to completion).
    /// When `onlyIn` is set, only that browser's tabs are considered, so opening a link
    /// never pulls the user out of the browser they're working in.
    public static func focusIfOpen(url: URL, onlyIn onlyBundleId: String? = nil) async -> Bool {
        let allowed: (String) -> Bool = { onlyBundleId == nil || $0 == onlyBundleId }
        let match = await withTaskGroup(of: OpenTab?.self) { group -> OpenTab? in
            for bundleId in supportedBundleIds where allowed(bundleId) && BrowserManager.isRunning(bundleId: bundleId) {
                group.addTask { URLMatch.best(for: url, among: tabs(bundleId: bundleId), url: \.url) }
            }
            // Each browser's best; the same page anywhere ends the search.
            var candidates: [OpenTab] = []
            for await result in group {
                guard let hit = result else { continue }
                if URLMatch.score(saved: url, open: hit.url) == URLMatch.samePage {
                    group.cancelAll()
                    return hit
                }
                candidates.append(hit)
            }
            return URLMatch.best(for: url, among: candidates, url: \.url)
        }
        guard let hit = match else { return false }
        return focus(tab: hit)
    }

    /// Every open tab across every running browser, each browser read once, for bulk lookups.
    public static func allTabs() async -> [OpenTab] {
        await withTaskGroup(of: [OpenTab].self) { group -> [OpenTab] in
            for bundleId in supportedBundleIds where BrowserManager.isRunning(bundleId: bundleId) {
                group.addTask { tabs(bundleId: bundleId) }
            }
            var collected: [OpenTab] = []
            for await list in group { collected.append(contentsOf: list) }
            return collected
        }
    }

    /// URL and title of the active tab in the front window of `bundleId`'s browser.
    public static func frontTab(bundleId: String) -> (url: URL, title: String)? {
        if let bridge = chromiumBridge(bundleId: bundleId) { return bridgeFrontTab(bridge) }
        guard let script = frontTabScript(bundleId: bundleId), let output = runAppleScript(script) else { return nil }
        return parseFrontTab(output)
    }

    static func frontTabScript(bundleId: String) -> String? {
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
        // Properties are read straight off the tab: Arc can't hold a tab in a variable.
        return """
        set sep to character id 9
        tell application "\(appName)"
            return (URL of \(tabExpr)) & sep & (\(titleKey) of \(tabExpr))
        end tell
        """
    }

    static func parseFrontTab(_ output: String) -> (url: URL, title: String)? {
        let cols = output.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        // Only web pages: a start page (favorites://, chrome://newtab) isn't worth stowing.
        guard let first = cols.first, let url = URL(string: String(first)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
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
        if let bridge = chromiumBridge(bundleId: bundleId) { return bridgeTabs(bridge, bundleId: bundleId) }
        guard let script = tabListScript(bundleId: bundleId) else { return [] }
        return parseRows(runAppleScript(script), bundleId: bundleId)
    }

    // MARK: - Focus

    static func focus(tab: OpenTab) -> Bool {
        if let bridge = chromiumBridge(bundleId: tab.bundleId) { return bridgeFocus(bridge, tab: tab) }
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

    // MARK: - Headless copies

    /// The pid of the browser copy that has windows when headless copies of the same app
    /// (Puppeteer, test runners) run beside it; nil for a lone instance, which AppleScript
    /// reaches by name. AppleScript can't pick among copies and may land on a headless one.
    static func windowedInstance(among instances: [(pid: pid_t, isRegular: Bool)]) -> pid_t? {
        guard instances.count > 1 else { return nil }
        return instances.first { $0.isRegular }?.pid
    }

    /// The windowed copy of a Chromium browser through ScriptingBridge, which addresses one
    /// process by pid, when headless copies are running too.
    private static func chromiumBridge(bundleId: String) -> (app: SBApplication, pid: pid_t)? {
        guard chromiumBrowsers.contains(where: { $0.bundleId == bundleId }) else { return nil }
        let instances = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleId }
            .map { (pid: $0.processIdentifier, isRegular: $0.activationPolicy == .regular) }
        guard let pid = windowedInstance(among: instances),
              let app = SBApplication(processIdentifier: pid) else { return nil }
        return (app, pid)
    }

    private static func bridgeWindows(_ app: SBApplication) -> [SBObject] {
        ((app.value(forKey: "windows") as? SBElementArray)?.get() as? [SBObject]) ?? []
    }

    private static func bridgeTabs(_ bridge: (app: SBApplication, pid: pid_t), bundleId: String) -> [OpenTab] {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        var tabs: [OpenTab] = []
        for window in bridgeWindows(bridge.app) {
            guard let windowId = window.value(forKey: "id").map({ "\($0)" }),
                  let list = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let urls = list.value(forKey: "URL") as? [String] ?? []
            let titles = list.value(forKey: "title") as? [String] ?? []
            for (i, string) in urls.enumerated() {
                guard let url = URL(string: string) else { continue }
                tabs.append(OpenTab(bundleId: bundleId, windowId: windowId, tabIndex: i + 1, url: url,
                                    title: i < titles.count ? titles[i] : ""))
            }
        }
        return tabs
    }

    private static func bridgeFrontTab(_ bridge: (app: SBApplication, pid: pid_t)) -> (url: URL, title: String)? {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        guard let front = bridgeWindows(bridge.app).first,
              let tab = front.value(forKey: "activeTab") as? SBObject,
              let url = tab.value(forKey: "URL") as? String else { return nil }
        return parseFrontTab(url + "\t" + (tab.value(forKey: "title") as? String ?? ""))
    }

    private static func bridgeFocus(_ bridge: (app: SBApplication, pid: pid_t), tab: OpenTab) -> Bool {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        guard let window = bridgeWindows(bridge.app).first(where: { $0.value(forKey: "id").map { "\($0)" } == tab.windowId }) else {
            return false
        }
        window.setValue(tab.tabIndex, forKey: "activeTabIndex")
        window.setValue(1, forKey: "index")
        return NSRunningApplication(processIdentifier: bridge.pid)?.activate() ?? false
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
