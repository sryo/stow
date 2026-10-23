import Foundation

/// When each link was last opened on this Mac, kept beside the data file and never
/// synced (an open is per device, and uploading one per click would be noise). A link
/// unopened for `staleAfterDays` since it was opened, or since this Mac first saw it,
/// reads as stale.
@MainActor
public final class LinkRecency {
    public static let staleAfterDays: Double = 60
    public static let shared = LinkRecency(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stow/recency.json")
    )

    private struct Stored: Codable {
        var opened: [UUID: Date] = [:]
        var firstSeen: [UUID: Date] = [:]
    }

    private let file: URL
    private let now: () -> Date
    private var stored: Stored

    public init(file: URL, now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
        stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public func noteOpened(_ id: UUID) {
        stored.opened[id] = now()
        save()
    }

    public func lastOpened(_ id: UUID) -> Date? { stored.opened[id] }

    public func isStale(_ id: UUID) -> Bool {
        let since: Date
        if let opened = stored.opened[id] {
            since = opened
        } else if let seen = stored.firstSeen[id] {
            since = seen
        } else {
            stored.firstSeen[id] = now()
            save()
            return false
        }
        return now().timeIntervalSince(since) > Self.staleAfterDays * 86_400
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
