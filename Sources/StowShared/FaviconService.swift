#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import os

@MainActor
public final class FaviconService {
    public static let shared = FaviconService()

    private var store = DataStore()
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

    /// Keeps icons under `baseDirectory`'s Icons folder from now on. The iPhone points
    /// this at the App Group so the widget and the Live Activity can draw the same files.
    public func useIcons(in baseDirectory: URL) {
        store = DataStore(baseDirectory: baseDirectory)
        cache.removeAll()
        cachedPaths.removeAll()
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
        let fileName = FaviconStorage.fileName(forHost: key)
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

/// How favicon files are named and found on disk, for every process that draws them.
public enum FaviconStorage {
    /// Icons are cached once per host: `example.com.ico`, `localhost_8080.ico`.
    public static func fileName(forHost host: String) -> String {
        host.lowercased().replacingOccurrences(of: ":", with: "_") + ".ico"
    }

    /// The name of `link`'s icon inside `iconsDirectory`, or nil when none is on disk.
    /// The host file comes first because `faviconPath` is absolute and may point into
    /// another process's container.
    public static func fileName(for link: Link, in iconsDirectory: URL) -> String? {
        var candidates: [String] = []
        let urlString = link.url.contains("://") ? link.url : "https://\(link.url)"
        if let host = URL(string: urlString)?.host, !host.isEmpty {
            candidates.append(fileName(forHost: host))
        }
        if let path = link.faviconPath {
            candidates.append((path as NSString).lastPathComponent)
        }
        return candidates.first { name in
            !name.isEmpty && FileManager.default.fileExists(atPath: iconsDirectory.appendingPathComponent(name).path)
        }
    }

    /// Moves every icon from `source` into `destination`, keeping a destination file
    /// that already exists. Returns how many files were moved.
    @discardableResult
    public static func moveIcons(from source: URL, to destination: URL) -> Int {
        let fileManager = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              let files = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
              !files.isEmpty else { return 0 }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = 0
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: file)
            } else if (try? fileManager.moveItem(at: file, to: target)) != nil {
                moved += 1
            }
        }
        return moved
    }
}
