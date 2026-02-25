import Foundation

public enum WorkspaceImportError: Error, LocalizedError {
    case invalidData
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The file is not a valid Stow workspace."
        case .unsupportedVersion(let version):
            return "This workspace requires Stow version \(version) or later."
        }
    }
}

public enum WorkspaceImporter {
    public static func importWorkspace(from data: Data, iconsDirectory: URL) throws -> Workspace {
        let decoder = JSONDecoder()
        let exported = try decoder.decode(ExportedWorkspace.self, from: data)

        guard exported.schemaVersion <= DataStore.currentSchemaVersion else {
            throw WorkspaceImportError.unsupportedVersion(exported.schemaVersion)
        }

        var workspace = exported.workspace
        // Generate new ID to avoid conflicts
        workspace.id = UUID()

        // Extract and cache favicons
        restoreFavicons(in: &workspace.items, from: exported.embeddedFavicons, iconsDirectory: iconsDirectory)

        return workspace
    }

    private static func restoreFavicons(in nodes: inout [Node], from favicons: [String: String], iconsDirectory: URL) {
        for i in nodes.indices {
            switch nodes[i] {
            case .link(var link):
                if let originalPath = link.faviconPath,
                   let base64 = favicons[originalPath],
                   let data = Data(base64Encoded: base64) {
                    let filename = UUID().uuidString + ".png"
                    let newPath = iconsDirectory.appendingPathComponent(filename).path
                    if FileManager.default.createFile(atPath: newPath, contents: data) {
                        link.faviconPath = newPath
                    } else {
                        link.faviconPath = nil
                    }
                } else {
                    link.faviconPath = nil
                }
                nodes[i] = .link(link)
            case .folder(var folder):
                restoreFavicons(in: &folder.children, from: favicons, iconsDirectory: iconsDirectory)
                nodes[i] = .folder(folder)
            case .task, .snippet:
                break
            }
        }
    }
}
