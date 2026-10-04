import AppKit
import Combine

/// Which pages are open in the browsers, and the page in front of the browser the Tabline
/// rides, for the rail's and the list's open dots and for the Tabline.
///
/// Every AppleScript runs on one serial queue, so the browsers are never scripted twice at
/// once. It polls only while a client wants it, and runs no script while no supported
/// browser is running. Each client says when it wants updates: the list while its window
/// is visible, the Tabline while it shows over a browser.
@MainActor
final class OpenTabsMonitor {
    struct FrontPage: Equatable, Sendable {
        let bundleId: String
        let url: URL
        let title: String
    }

    /// The browser reads, swappable in tests. They run on the monitor's queue.
    struct Reader: Sendable {
        var browsersRunning: @Sendable () -> Bool
        var openURLs: @Sendable () -> [URL]
        var frontPage: @Sendable (_ bundleId: String) -> FrontPage?

        static let live = Reader(
            browsersRunning: { BrowserTabService.anySupportedBrowserRunning() },
            openURLs: { BrowserTabService.listTabs().map(\.url) },
            frontPage: { bundleId in
                BrowserTabService.frontTab(bundleId: bundleId).map { FrontPage(bundleId: bundleId, url: $0.url, title: $0.title) }
            }
        )
    }

    enum Client: Hashable {
        case list, tabline
    }

    static let shared = OpenTabsMonitor(reader: .live, seed: OpenTabsMonitor.debugSeed)

    /// Canonical URLs (`URLCanonical.key`) of every open tab.
    @Published private(set) var openKeys: Set<String> = []
    /// The page in front of `frontBundleId`'s browser.
    @Published private(set) var frontPage: FrontPage?
    /// The browser whose front page is read; the Tabline sets it to the one it rides.
    var frontBundleId: String? {
        didSet {
            guard frontBundleId != oldValue else { return }
            frontPage = nil
            readFrontPage()
        }
    }

    /// Front page every tick, open tabs every `tabsEvery` ticks.
    private static let tick: TimeInterval = 1.5
    private static let tabsEvery = 3

    private let reader: Reader
    private let seed: Set<String>?
    private let queue = DispatchQueue(label: "com.stow.open-tabs", qos: .utility)
    private var demand: Set<Client> = []
    private var timer: Timer?
    private var ticks = 0
    private var isReadingTabs = false
    private var isReadingFront = false

    /// A non-nil `seed` stands in for the browsers' open tabs.
    init(reader: Reader, seed: Set<String>?) {
        self.reader = reader
        self.seed = seed
        if let seed { openKeys = seed }
    }

    func setDemand(_ client: Client, _ wanted: Bool) {
        if wanted {
            guard demand.insert(client).inserted else { return }
            startTimer()
            readOpenTabs()
            readFrontPage()
        } else {
            guard demand.remove(client) != nil else { return }
            if demand.isEmpty { stopTimer() }
        }
    }

    /// Reads now instead of at the next tick, e.g. when the window comes forward.
    func refreshNow() {
        readOpenTabs()
        readFrontPage()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFired() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickFired() {
        ticks += 1
        readFrontPage()
        if ticks % Self.tabsEvery == 0 { readOpenTabs() }
    }

    private func readOpenTabs() {
        guard !demand.isEmpty, seed == nil, !isReadingTabs else { return }
        isReadingTabs = true
        queue.async { [reader] in
            let urls = reader.browsersRunning() ? reader.openURLs() : []
            let keys = Set(urls.map { URLCanonical.key($0) })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReadingTabs = false
                if keys != self.openKeys { self.openKeys = keys }
            }
        }
    }

    private func readFrontPage() {
        guard demand.contains(.tabline), let bundleId = frontBundleId, !isReadingFront else { return }
        isReadingFront = true
        queue.async { [reader] in
            let page = reader.browsersRunning() ? reader.frontPage(bundleId) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReadingFront = false
                guard self.frontBundleId == bundleId, page != self.frontPage else { return }
                self.frontPage = page
            }
        }
    }

    /// STOW_OPEN_TABS (comma-separated URLs) stands in for the browsers, for screenshots.
    private static var debugSeed: Set<String>? {
        #if DEBUG
        ProcessInfo.processInfo.environment["STOW_OPEN_TABS"].map { list in
            Set(list.split(separator: ",").compactMap { URL(string: String($0)) }.map { URLCanonical.key($0) })
        }
        #else
        nil
        #endif
    }
}
