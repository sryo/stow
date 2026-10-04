import Foundation

/// File ▸ Export All…: the whole library as Stow JSON (restorable with Restore from
/// Backup… or Import…) or as a bookmarks HTML file any browser imports.
enum LibraryExport {
    static func json(_ state: AppState) throws -> Data {
        var state = state
        state.isSettingsSelected = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    /// Reads an Export All JSON file or a backup snapshot.
    static func state(fromBackup data: Data) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: data)
    }

    static func html(_ state: AppState) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Stow</TITLE>
        <H1>Stow</H1>
        <DL><p>

        """
        for workspace in state.workspaces {
            out += "    <DT><H3>\(escape(workspace.name))</H3>\n    <DL><p>\n"
            write(workspace.items, depth: 2, into: &out)
            out += "    </DL><p>\n"
        }
        out += "</DL><p>\n"
        return out
    }

    private static func write(_ nodes: [Node], depth: Int, into out: inout String) {
        let pad = String(repeating: "    ", count: depth)
        for node in nodes {
            switch node {
            case .link(let link):
                out += "\(pad)<DT><A HREF=\"\(escape(link.url))\">\(escape(link.title))</A>\n"
            case .folder(let folder):
                out += "\(pad)<DT><H3>\(escape(folder.name))</H3>\n\(pad)<DL><p>\n"
                write(folder.children, depth: depth + 1, into: &out)
                out += "\(pad)</DL><p>\n"
            case .task, .snippet:
                continue
            }
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Silent daily snapshots of data.json in Backups/, the newest 14 kept, for Restore from
/// Backup… after a bad import or sync.
struct BackupService {
    static let keep = 14

    struct Backup: Equatable {
        let url: URL
        let date: Date
    }

    let baseDirectory: URL
    var dataURL: URL { baseDirectory.appendingPathComponent("data.json") }
    var directory: URL { baseDirectory.appendingPathComponent("Backups", isDirectory: true) }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    /// Copies data.json once per day.
    func backUpIfNeeded(now: Date = Date()) {
        let day = Self.dayFormat.string(from: now)
        guard FileManager.default.fileExists(atPath: dataURL.path),
              !list().contains(where: { Self.dayFormat.string(from: $0.date) == day }) else { return }
        snapshot(named: "data-\(Self.stampFormat.string(from: now)).json")
        prune()
    }

    private func snapshot(named name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: dataURL, to: target)
    }

    private func prune() {
        for backup in list().dropFirst(Self.keep) { try? FileManager.default.removeItem(at: backup.url) }
    }

    /// Newest first.
    func list() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("data-"), let date = Self.stampFormat.date(from: String(name.dropFirst(5))) else { return nil }
            return Backup(url: url, date: date)
        }.sorted { $0.date > $1.date }
    }

    /// Replaces data.json with `backup`, first keeping the current data as a backup.
    func restore(_ backup: Backup, now: Date = Date()) throws {
        let data = try Data(contentsOf: backup.url)
        if FileManager.default.fileExists(atPath: dataURL.path) {
            snapshot(named: "data-\(Self.stampFormat.string(from: now)).json")
        }
        try data.write(to: dataURL, options: .atomic)
        prune()
    }
}
