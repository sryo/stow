import Foundation
import os

@MainActor
public final class LinkTitleService {
    public static let shared = LinkTitleService()

    private let session: URLSession
    private let logger = Logger(subsystem: "com.stow.app", category: "title")
    private var inFlight: Set<UUID> = []

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml"]
        self.session = URLSession(configuration: config)
    }

    public func fetchTitle(for url: URL, linkId: UUID, completion: @escaping (String?) -> Void) {
        if inFlight.contains(linkId) {
            completion(nil)
            return
        }
        inFlight.insert(linkId)
        logger.debug("Fetching title for \(url.absoluteString, privacy: .public)")

        Task {
            defer { inFlight.remove(linkId) }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    logger.debug("Title fetch non-200 for \(url.absoluteString, privacy: .public)")
                    completion(nil)
                    return
                }

                let limitedData = data.prefix(200_000)
                let encoding = stringEncoding(from: response) ?? .utf8
                let html = String(data: limitedData, encoding: encoding) ?? String(data: limitedData, encoding: .utf8)
                guard let html, let title = extractTitle(from: html) else {
                    logger.debug("Title parse failed for \(url.absoluteString, privacy: .public)")
                    completion(nil)
                    return
                }

                let cleaned = title
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                completion(cleaned.isEmpty ? nil : cleaned)
            } catch {
                logger.debug("Title fetch error for \(url.absoluteString, privacy: .public)")
                completion(nil)
            }
        }
    }

    private func stringEncoding(from response: URLResponse) -> String.Encoding? {
        if let textEncodingName = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(textEncodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                return String.Encoding(rawValue: nsEncoding)
            }
        }
        return nil
    }

    private func extractTitle(from html: String) -> String? {
        let lower = html.lowercased()
        guard let startRange = lower.range(of: "<title") else { return nil }
        guard let tagEndRange = lower.range(of: ">", range: startRange.upperBound..<lower.endIndex) else { return nil }
        guard let endRange = lower.range(of: "</title>", range: tagEndRange.upperBound..<lower.endIndex) else { return nil }
        let rawTitle = html[tagEndRange.upperBound..<endRange.lowerBound]
        return String(rawTitle)
    }
}
