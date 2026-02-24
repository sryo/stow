import Foundation
import Compression

enum ShareError: Error, LocalizedError {
    case workspaceNotFound
    case urlTooLarge(Int)
    case compressionFailed
    case decompressionFailed
    case invalidBase64
    case invalidData

    var errorDescription: String? {
        switch self {
        case .workspaceNotFound:
            return "Workspace not found."
        case .urlTooLarge(let size):
            return "Share URL is too large (\(size / 1024)KB). Try removing some items from the workspace."
        case .compressionFailed:
            return "Failed to compress workspace data."
        case .decompressionFailed:
            return "Failed to decompress shared workspace data."
        case .invalidBase64:
            return "Invalid share link. The data could not be decoded."
        case .invalidData:
            return "Invalid share link. The workspace data is corrupted."
        }
    }
}

enum ShareService {
    static let baseURL = "https://stow.app/share"
    private static let maxURLSize = 32 * 1024 // 32KB

    static func createShareURL(workspace: Workspace, schemaVersion: Int) throws -> String {
        let stripped = stripFavicons(from: workspace)
        let exported = ExportedWorkspace(
            schemaVersion: schemaVersion,
            workspace: stripped,
            embeddedFavicons: [:]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(exported)

        let compressed = try compress(jsonData)
        let encoded = base64urlEncode(compressed)
        let url = "\(baseURL)#\(encoded)"

        guard url.count <= maxURLSize else {
            throw ShareError.urlTooLarge(url.count)
        }

        return url
    }

    static func decodeShareData(from fragment: String) throws -> Data {
        let compressed = try base64urlDecode(fragment)
        let decompressed = try decompress(compressed)
        return decompressed
    }

    // MARK: - Private

    private static func stripFavicons(from workspace: Workspace) -> Workspace {
        var stripped = workspace
        stripped.items = stripFaviconsFromNodes(stripped.items)
        return stripped
    }

    private static func stripFaviconsFromNodes(_ nodes: [Node]) -> [Node] {
        nodes.map { node in
            switch node {
            case .link(var link):
                link.faviconPath = nil
                return .link(link)
            case .folder(var folder):
                folder.children = stripFaviconsFromNodes(folder.children)
                return .folder(folder)
            case .task, .snippet:
                return node
            }
        }
    }

    static func compress(_ data: Data) throws -> Data {
        let sourceSize = data.count
        // Worst case: compressed data could be slightly larger than source
        let destinationBufferSize = max(sourceSize * 2, 128)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationBufferSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                destinationBufferSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                sourceSize,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else {
            throw ShareError.compressionFailed
        }

        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    static func decompress(_ data: Data) throws -> Data {
        // Start with a reasonable buffer, grow if needed
        let maxDecompressedSize = 1024 * 1024 // 1MB safety limit
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxDecompressedSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourcePtr -> Int in
            guard let baseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                maxDecompressedSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw ShareError.decompressionFailed
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    static func base64urlEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ string: String) throws -> Data {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw ShareError.invalidBase64
        }
        return data
    }
}
