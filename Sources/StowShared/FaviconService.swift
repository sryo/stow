#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import os

@MainActor
public final class FaviconService {
    public static let shared = FaviconService()

    private let store = DataStore()
    private let session: URLSession
    private let logger = Logger(subsystem: "com.stow.app", category: "favicon")
    private let failureCooldown: TimeInterval = 300
    private var cache: [String: PlatformImage] = [:]
    private var cachedPaths: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var pendingCallbacks: [String: [(PlatformImage?, String?) -> Void]] = [:]
    private var failureTimestamps: [String: Date] = [:]

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
    }

    public func favicon(for url: URL, cachedPath: String?, completion: @escaping (PlatformImage?, String?) -> Void) {
        guard let host = url.host else {
            completeAsync(completion, image: nil, path: nil)
            return
        }

        let key = host.lowercased()
        if key == "localhost" || key == "127.0.0.1" {
            completeAsync(completion, image: nil, path: nil)
            return
        }

        if let lastFailure = failureTimestamps[key], Date().timeIntervalSince(lastFailure) < failureCooldown {
            logger.debug("Skipping favicon fetch for \(key, privacy: .public) due to cooldown")
            completeAsync(completion, image: nil, path: nil)
            return
        }

        if let image = cache[key] {
            let path = cachedPaths[key]
            completeAsync(completion, image: image, path: path)
            return
        }

        let iconsDir = store.iconsDirectory()
        let fileName = key.replacingOccurrences(of: ":", with: "_") + ".ico"
        let fileURL = iconsDir.appendingPathComponent(fileName)

        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath),
           let image = loadImage(fromPath: cachedPath) {
            cache[key] = image
            cachedPaths[key] = cachedPath
            completeAsync(completion, image: image, path: cachedPath)
            return
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let image = loadImage(fromURL: fileURL) {
            cache[key] = image
            cachedPaths[key] = fileURL.path
            completeAsync(completion, image: image, path: fileURL.path)
            return
        }

        if inFlight.contains(key) {
            logger.debug("Queueing callback for in-flight request: \(key, privacy: .public)")
            pendingCallbacks[key, default: []].append(completion)
            return
        }
        inFlight.insert(key)
        logger.debug("Fetching favicon for \(key, privacy: .public)")

        Task {
            let scheme = url.scheme ?? "https"
            let primaryURL = URL(string: "\(scheme)://\(host)/favicon.ico")
            let fallbackURL = URL(string: "https://www.google.com/s2/favicons?sz=64&domain_url=\(scheme)://\(host)")

            let data = await fetchFaviconData(primary: primaryURL, fallback: fallbackURL)
            defer {
                inFlight.remove(key)
                pendingCallbacks.removeValue(forKey: key)
            }

            guard let data, let image = PlatformImage(data: data) else {
                failureTimestamps[key] = Date()
                logger.debug("Favicon fetch failed for \(key, privacy: .public)")
                completeAsync(completion, image: nil, path: nil)
                // Notify all pending callbacks of the failure
                let callbacks = pendingCallbacks[key] ?? []
                for callback in callbacks {
                    completeAsync(callback, image: nil, path: nil)
                }
                return
            }

            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                logger.debug("Failed to write favicon for \(key, privacy: .public)")
            }

            cache[key] = image
            cachedPaths[key] = fileURL.path
            logger.debug("Favicon fetch succeeded for \(key, privacy: .public)")
            completeAsync(completion, image: image, path: fileURL.path)

            // Notify all pending callbacks of the success
            let callbacks = pendingCallbacks[key] ?? []
            logger.debug("Notifying \(callbacks.count, privacy: .public) pending callbacks for \(key, privacy: .public)")
            for callback in callbacks {
                completeAsync(callback, image: image, path: fileURL.path)
            }
        }
    }

    private func loadImage(fromPath path: String) -> PlatformImage? {
        #if canImport(AppKit)
        return NSImage(contentsOfFile: path)
        #elseif canImport(UIKit)
        return UIImage(contentsOfFile: path)
        #endif
    }

    private func loadImage(fromURL url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        return NSImage(contentsOf: url)
        #elseif canImport(UIKit)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
        #endif
    }

    private func completeAsync(_ completion: @escaping (PlatformImage?, String?) -> Void, image: PlatformImage?, path: String?) {
        DispatchQueue.main.async {
            completion(image, path)
        }
    }

    private func fetchFaviconData(primary: URL?, fallback: URL?) async -> Data? {
        if let primary {
            if let data = await fetchData(from: primary) {
                return data
            }
        }
        if let fallback {
            return await fetchData(from: fallback)
        }
        return nil
    }

    private func fetchData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                return data
            }
        } catch {
            logger.debug("Favicon fetch error \(url.absoluteString, privacy: .public)")
        }
        return nil
    }
}
