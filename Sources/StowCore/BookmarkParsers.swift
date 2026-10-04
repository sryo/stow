import Foundation

/// Where File ▸ Import… can bring bookmarks from.
enum ImportSource: Equatable {
    case arc
    case chromium(bundleId: String, name: String)
    case safari
    case htmlFile
    case stowFile
    case stowBackup

    /// The kind of a file chosen in a panel or dropped on the window.
    static func forFile(_ url: URL) -> ImportSource? {
        switch url.pathExtension.lowercased() {
        case "stow": return .stowFile
        case "html", "htm": return .htmlFile
        case "json": return .stowBackup
        default: return nil
        }
    }
}

enum BookmarkParseError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let what): return "Couldn't read \(what)."
        }
    }
}

/// Turns other browsers' bookmark files into workspaces: one workspace per top-level
/// bookmark collection, folders kept as folders.
enum BookmarkParsers {
    // MARK: Chrome and other Chromium browsers

    /// Chromium's `Bookmarks` JSON: roots → bookmark_bar / other / synced.
    static func chrome(_ data: Data, browserName: String) throws -> [ImportWorkspace] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw BookmarkParseError.unreadable("\(browserName)'s bookmarks") }
        var result: [ImportWorkspace] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[key] as? [String: Any] else { continue }
            let nodes = chromeChildren(root["children"] as? [[String: Any]] ?? [])
            guard !nodes.isEmpty else { continue }
            let name = (root["name"] as? String) ?? key
            result.append(ImportWorkspace(name: "\(browserName) · \(name)", colorId: .defaultColor(), nodes: nodes))
        }
        return result
    }

    private static func chromeChildren(_ items: [[String: Any]]) -> [Node] {
        items.compactMap { item in
            switch item["type"] as? String {
            case "url":
                guard let url = item["url"] as? String else { return nil }
                return .link(Link(id: UUID(), title: (item["name"] as? String) ?? url, url: url, faviconPath: nil))
            case "folder":
                let children = chromeChildren(item["children"] as? [[String: Any]] ?? [])
                return .folder(Folder(id: UUID(), name: (item["name"] as? String) ?? "Folder", children: children, isExpanded: false))
            default:
                return nil
            }
        }
    }

    // MARK: HTML (Netscape bookmark file)

    /// The bookmarks HTML every browser exports. Folders (`<H3>`) nest by `<DL>`.
    static func netscapeHTML(_ html: String, name: String) -> [ImportWorkspace] {
        var stack: [[Node]] = [[]]
        var folderNames: [String] = []
        var pendingFolder: String?
        let scanner = Scanner(string: html)
        scanner.charactersToBeSkipped = nil
        while !scanner.isAtEnd {
            _ = scanner.scanUpToString("<")
            guard scanner.scanString("<") != nil else { break }
            let tag = (scanner.scanUpToString(">") ?? "")
            _ = scanner.scanString(">")
            let lower = tag.lowercased()
            if lower.hasPrefix("h3") {
                let title = scanner.scanUpToString("</") ?? ""
                pendingFolder = decodeEntities(title.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if lower == "dl" || lower.hasPrefix("dl ") {
                folderNames.append(pendingFolder ?? "")
                stack.append([])
                pendingFolder = nil
            } else if lower == "/dl" {
                guard stack.count > 1 else { continue }
                let children = stack.removeLast()
                let folderName = folderNames.removeLast()
                if stack.count == 1 && folderName.isEmpty {
                    // The file's outer list: its items are the top level.
                    stack[0].append(contentsOf: children)
                } else {
                    stack[stack.count - 1].append(.folder(Folder(id: UUID(), name: folderName.isEmpty ? "Folder" : folderName,
                                                                 children: children, isExpanded: false)))
                }
            } else if lower.hasPrefix("a ") {
                let title = scanner.scanUpToString("</") ?? ""
                guard let href = attribute("href", in: tag) else { continue }
                let text = decodeEntities(title.trimmingCharacters(in: .whitespacesAndNewlines))
                stack[stack.count - 1].append(.link(Link(id: UUID(), title: text.isEmpty ? href : text, url: decodeEntities(href), faviconPath: nil)))
            }
        }
        while stack.count > 1 {
            let children = stack.removeLast()
            stack[stack.count - 1].append(contentsOf: children)
        }
        let nodes = stack[0]
        return nodes.isEmpty ? [] : [ImportWorkspace(name: name, colorId: .defaultColor(), nodes: nodes)]
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"", options: .caseInsensitive) else { return nil }
        let rest = tag[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }

    // MARK: Safari

    /// Safari's Bookmarks.plist: Favorites (BookmarksBar) and the Bookmarks menu become
    /// workspaces; Reading List and History are skipped.
    static func safari(_ data: Data) throws -> [ImportWorkspace] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BookmarkParseError.unreadable("Safari's bookmarks")
        }
        let names = ["BookmarksBar": "Favorites", "BookmarksMenu": "Bookmarks Menu"]
        var result: [ImportWorkspace] = []
        var loose: [Node] = []
        for child in root["Children"] as? [[String: Any]] ?? [] {
            let title = child["Title"] as? String ?? ""
            if title == "com.apple.ReadingList" || child["WebBookmarkType"] as? String == "WebBookmarkTypeProxy" { continue }
            if child["WebBookmarkType"] as? String == "WebBookmarkTypeList" {
                let nodes = safariChildren(child["Children"] as? [[String: Any]] ?? [])
                guard !nodes.isEmpty else { continue }
                result.append(ImportWorkspace(name: "Safari · \(names[title] ?? title)", colorId: .defaultColor(), nodes: nodes))
            } else if let node = safariChildren([child]).first {
                loose.append(node)
            }
        }
        if !loose.isEmpty { result.append(ImportWorkspace(name: "Safari", colorId: .defaultColor(), nodes: loose)) }
        return result
    }

    private static func safariChildren(_ items: [[String: Any]]) -> [Node] {
        items.compactMap { item in
            switch item["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = item["URLString"] as? String else { return nil }
                let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
                return .link(Link(id: UUID(), title: title, url: url, faviconPath: nil))
            case "WebBookmarkTypeList":
                return .folder(Folder(id: UUID(), name: item["Title"] as? String ?? "Folder",
                                      children: safariChildren(item["Children"] as? [[String: Any]] ?? []), isExpanded: false))
            default:
                return nil
            }
        }
    }
}
