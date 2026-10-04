import Foundation
import os

public final class DataStore {
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let dataURL: URL
    private let logger = Logger(subsystem: "com.stow.app", category: "datastore")
    /// Invoked when a save fails (encode error, disk full, permissions).
    /// Persistence stays non-throwing so mutation paths never crash; hosts
    /// wire this to surface the failure — the in-memory state stays live and
    /// the next successful save wins.
    public var onSaveError: ((Error) -> Void)?

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("Stow", isDirectory: true)
        }
        self.dataURL = self.baseDirectory.appendingPathComponent("data.json")
    }

    public static let currentSchemaVersion = 2

    public func load() -> AppState {
        ensureDirectories()
        guard fileManager.fileExists(atPath: dataURL.path) else {
            let defaultState = Self.defaultState()
            save(defaultState)
            return defaultState
        }

        do {
            let data = try Data(contentsOf: dataURL)
            let decoder = JSONDecoder()
            var state = try decoder.decode(AppState.self, from: data)
            // Refuse to load a future schema version — a downgrade would silently
            // drop fields the older build doesn't decode. Preserve the file and
            // surface an empty state until the user reinstalls the newer build.
            if state.schemaVersion > Self.currentSchemaVersion {
                preserveCorruptFile(reason: "futureSchema_v\(state.schemaVersion)")
                return Self.defaultState()
            }
            if state.schemaVersion < Self.currentSchemaVersion {
                state = migrate(state: state, from: state.schemaVersion, to: Self.currentSchemaVersion)
                save(state)
            }
            return state
        } catch {
            // Don't overwrite the unreadable file — preserving it lets the user
            // (or a future migration) recover. Save a default to a SEPARATE path
            // so the next save doesn't clobber the preserved copy.
            preserveCorruptFile(reason: "decode_\(type(of: error))")
            let fallback = Self.defaultState()
            save(fallback)
            return fallback
        }
    }

    private func preserveCorruptFile(reason: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let preserved = baseDirectory.appendingPathComponent("data.json.corrupt-\(stamp)-\(reason)")
        try? fileManager.moveItem(at: dataURL, to: preserved)
    }

    public func migrate(state: AppState, from oldVersion: Int, to newVersion: Int) -> AppState {
        var state = state
        // v1 -> v2: Additive only (new task/snippet node types). No data transformation needed.
        if oldVersion < 2 {
            state.schemaVersion = 2
        }
        return state
    }

    public func save(_ state: AppState) {
        ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: dataURL, options: [.atomic])
        } catch {
            logger.error("Failed to save data.json: \(error.localizedDescription, privacy: .public)")
            onSaveError?(error)
        }
    }

    /// Deletes icon files no longer referenced by any link. Favicons are
    /// cached per-host and shared across links — and FaviconService also
    /// resolves icons by host-derived filename when a link's faviconPath is
    /// nil — so a file is kept while any link's path OR host still maps to it.
    public func cleanOrphanedFavicons(state: AppState) {
        let iconsURL = baseDirectory.appendingPathComponent("Icons", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: iconsURL, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        var referenced = Set<String>()
        for workspace in state.workspaces {
            for link in workspace.items.flattenLinks() {
                if let path = link.faviconPath {
                    referenced.insert((path as NSString).lastPathComponent)
                }
                if let host = URL(string: link.url)?.host {
                    referenced.insert(FaviconStorage.fileName(forHost: host))
                }
            }
        }

        for file in files where !referenced.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    public func iconsDirectory() -> URL {
        let iconsURL = baseDirectory.appendingPathComponent("Icons", isDirectory: true)
        if !fileManager.fileExists(atPath: iconsURL.path) {
            try? fileManager.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        }
        return iconsURL
    }

    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    public static func defaultState() -> AppState {
        let workspace = Workspace(
            id: UUID(),
            name: Workspace.defaultName,
            colorId: .defaultColor(),
            items: []
        )
        return AppState(schemaVersion: currentSchemaVersion, workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)
    }
}
