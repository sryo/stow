import AppKit
import StowShared

extension Notification.Name {
    /// A link's favicon was fetched: userInfo has "linkId" (UUID) and "path" (String).
    static let stowLinkFaviconFetched = Notification.Name("StowLinkFaviconFetched")
}

/// The one way the Mac app asks for missing favicons (list rows, mosaic tiles, the rail,
/// Settings tiles). Each link is requested once; one that came back empty is tried again
/// only after the cooldown, and each workspace starts at most `perWorkspaceCap` fetches per
/// cooldown, so a large import doesn't fire hundreds at once. Results are posted as
/// `.stowLinkFaviconFetched`; MainViewController writes them into the library.
@MainActor
final class FaviconPrefetcher {
    typealias Fetch = (URL, @escaping (String?) -> Void) -> Void

    static let shared = FaviconPrefetcher(fetch: { url, done in
        FaviconService.shared.favicon(for: url, cachedPath: nil) { _, path in done(path) }
    })

    private let fetch: Fetch
    private let fileExists: (String) -> Bool
    private let now: () -> Date
    let perWorkspaceCap: Int
    let cooldown: TimeInterval

    /// When each link was last asked for, and whether that request is still out.
    private var requested: [UUID: Date] = [:]
    private var inFlight: Set<UUID> = []
    /// Fetches started per workspace in the current window, and when that window opened.
    private var budget: [UUID: (start: Date, used: Int)] = [:]
    private static let noWorkspace = UUID(uuidString: "00000000-0000-0000-0000-00000000F4F1")!

    init(fetch: @escaping Fetch,
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
         now: @escaping () -> Date = Date.init,
         perWorkspaceCap: Int = 60, cooldown: TimeInterval = 300) {
        self.fetch = fetch
        self.fileExists = fileExists
        self.now = now
        self.perWorkspaceCap = perWorkspaceCap
        self.cooldown = cooldown
    }

    /// Whether a link has no usable favicon on disk.
    func needsFavicon(_ link: Link) -> Bool {
        guard let path = link.faviconPath else { return true }
        return !fileExists(path)
    }

    /// Asks for the favicons `links` are missing, charged to `workspaceId`'s cap.
    func request(links: [Link], in workspaceId: UUID?) {
        let key = workspaceId ?? Self.noWorkspace
        let time = now()
        var window = budget[key] ?? (time, 0)
        if time.timeIntervalSince(window.start) >= cooldown { window = (time, 0) }
        defer { budget[key] = window }
        for link in links where needsFavicon(link) {
            guard window.used < perWorkspaceCap else { return }
            guard !inFlight.contains(link.id) else { continue }
            if let last = requested[link.id], time.timeIntervalSince(last) < cooldown { continue }
            guard let url = URL(string: link.url) else { continue }
            requested[link.id] = time
            inFlight.insert(link.id)
            window.used += 1
            let id = link.id
            fetch(url) { [weak self] path in
                MainActor.assumeIsolated {
                    self?.inFlight.remove(id)
                    guard let path else { return }
                    NotificationCenter.default.post(name: .stowLinkFaviconFetched, object: nil,
                                                    userInfo: ["linkId": id, "path": path])
                }
            }
        }
    }
}
