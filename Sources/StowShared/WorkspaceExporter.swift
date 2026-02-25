import Foundation

public struct ExportedWorkspace: Codable {
    public var schemaVersion: Int
    public var workspace: Workspace
    public var embeddedFavicons: [String: String] // faviconPath -> base64 data

    public init(schemaVersion: Int, workspace: Workspace, embeddedFavicons: [String: String]) {
        self.schemaVersion = schemaVersion
        self.workspace = workspace
        self.embeddedFavicons = embeddedFavicons
    }
}

public enum WorkspaceExporter {
    public static func export(workspace: Workspace, schemaVersion: Int) throws -> Data {
        var favicons: [String: String] = [:]

        // Embed favicons as base64
        collectFavicons(from: workspace.items, into: &favicons)

        let exported = ExportedWorkspace(
            schemaVersion: schemaVersion,
            workspace: workspace,
            embeddedFavicons: favicons
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exported)
    }

    private static func collectFavicons(from nodes: [Node], into favicons: inout [String: String]) {
        for node in nodes {
            switch node {
            case .link(let link):
                if let path = link.faviconPath,
                   FileManager.default.fileExists(atPath: path),
                   let data = FileManager.default.contents(atPath: path) {
                    favicons[path] = data.base64EncodedString()
                }
            case .folder(let folder):
                collectFavicons(from: folder.children, into: &favicons)
            case .task, .snippet:
                break
            }
        }
    }
}
