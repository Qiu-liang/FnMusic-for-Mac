import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

/// Share one instance per server/account namespace. A namespace is an identity,
/// not a credential: callers must replace/clear the cache when signing out.
actor ImageCache {
    enum CacheError: Error, LocalizedError, Sendable {
        case invalidCover, invalidImage, unsafeCachePath

        var errorDescription: String? {
            switch self {
            case .invalidCover: "封面标识为空。"
            case .invalidImage: "无法解码封面图片。"
            case .unsafeCachePath: "图片缓存路径校验失败，已停止磁盘操作。"
            }
        }
    }

    private struct Key: Hashable, Sendable {
        let id: String
        let size: Int
        var filename: String { ImageCache.digest("\(size):\(id)") + ".image" }
    }

    // CGImage is immutable and Sendable in the macOS SDK. NSCache and this
    // NSObject wrapper never leave the actor; no unchecked Sendable is needed.
    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private struct Loaded: Sendable {
        let image: CGImage
        let downloadedData: Data?
    }

    private struct Flight {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CGImage, any Error>]
    }

    private struct DiskEntry {
        let url: URL
        let bytes: Int64
        let lastAccess: Date
    }

    private let client: APIClient
    private let namespaceHash: String
    private let cacheRoot: URL
    private let memory = NSCache<NSString, ImageBox>()
    private var flights: [Key: Flight] = [:]
    private var preparedDisk = false
    private static let diskLimit: Int64 = 200 * 1_024 * 1_024

    init(client: APIClient, namespace: String) {
        self.client = client
        let hash = Self.digest(namespace)
        namespaceHash = hash
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheRoot = caches.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("dev.fnmusic.mac", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true).standardizedFileURL
        memory.totalCostLimit = 64 * 1_024 * 1_024
        memory.countLimit = 256
    }

    /// Only the documented 160/600 variants are requested. Other sizes map to
    /// 160 (<=160) or 600. Return values are decoded off the main actor.
    func image(id: String, size: Int = 600) async throws -> CGImage {
        try Task.checkCancellation()
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CacheError.invalidCover
        }
        let key = Key(id: id, size: size <= 160 ? 160 : 600)
        if let hit = memory.object(forKey: key.filename as NSString) { return hit.image }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let image: CGImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var flight = flights[key] {
                    flight.waiters[waiter] = continuation
                    flights[key] = flight
                    return
                }
                let token = UUID()
                let client = self.client
                let task = Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    let result: Result<Loaded, any Error>
                    do {
                        try Task.checkCancellation()
                        let cached = await self.cachedData(for: key)
                        let loaded: Loaded
                        if let cached, let image = try? Self.decode(cached, size: key.size) {
                            loaded = Loaded(image: image, downloadedData: nil)
                        } else {
                            try Task.checkCancellation()
                            // All authentication, transport and HTTP validation
                            // belong to APIClient; never construct a URL here.
                            let data = try await client.cover(id: key.id, size: key.size)
                            try Task.checkCancellation()
                            loaded = Loaded(image: try Self.decode(data, size: key.size), downloadedData: data)
                        }
                        try Task.checkCancellation()
                        result = .success(loaded)
                    } catch { result = .failure(error) }
                    await self.finish(key: key, token: token, result: result)
                }
                flights[key] = Flight(token: token, task: task, waiters: [waiter: continuation])
            }
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    /// Cancels pending consumers and removes ONLY this namespace's directory.
    /// The actor performs the removal without suspension, so old downloads
    /// cannot repopulate the disk after clear() returns.
    func clear() async throws {
        for flight in flights.values {
            flight.task.cancel()
            for continuation in flight.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
        flights.removeAll()
        memory.removeAllObjects()
        preparedDisk = false
        try validateRoot()
        if FileManager.default.fileExists(atPath: cacheRoot.path) {
            try FileManager.default.removeItem(at: cacheRoot)
        }
    }

    /// Current namespace's encoded image bytes, not decoded memory or other
    /// namespaces. Filesystem errors are exposed to the settings UI.
    func diskUsage() async throws -> Int64 {
        try prepareDisk()
        return try entries().reduce(0) { $0 + $1.bytes }
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task.cancel()
            flights.removeValue(forKey: key)
        } else {
            flights[key] = flight
        }
    }

    private func finish(key: Key, token: UUID, result: Result<Loaded, any Error>) {
        // Token also protects a new request from an old, cancelled completion.
        guard let flight = flights[key], flight.token == token else { return }
        flights.removeValue(forKey: key)
        switch result {
        case .success(let loaded):
            memory.setObject(ImageBox(loaded.image), forKey: key.filename as NSString,
                             cost: loaded.image.bytesPerRow * loaded.image.height)
            // Disk failure must not turn an otherwise usable cover into an error.
            if let data = loaded.downloadedData { try? store(data, for: key) }
            for continuation in flight.waiters.values { continuation.resume(returning: loaded.image) }
        case .failure(let error):
            for continuation in flight.waiters.values { continuation.resume(throwing: error) }
        }
    }

    private nonisolated static func decode(_ data: Data, size: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CacheError.invalidImage }
        try Task.checkCancellation()
        return image
    }

    private func cachedData(for key: Key) -> Data? {
        do {
            try prepareDisk()
            let url = cacheRoot.appendingPathComponent(key.filename)
            try validateFile(url)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let bytes = values.fileSize,
                  bytes > 0, Int64(bytes) <= Self.diskLimit else { return nil }
            let data = try Data(contentsOf: url)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return data
        } catch { return nil }
    }

    private func store(_ data: Data, for key: Key) throws {
        guard Int64(data.count) <= Self.diskLimit else { return }
        try prepareDisk()
        let url = cacheRoot.appendingPathComponent(key.filename)
        try validateFile(url)
        // Evict first so a successful write never exceeds the encoded-byte cap.
        try trim(reserving: Int64(data.count), replacing: url)
        try data.write(to: url, options: .atomic)
    }

    private func prepareDisk() throws {
        try validateRoot()
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try validateRoot()
        if !preparedDisk {
            try trim(reserving: 0, replacing: nil)
            preparedDisk = true
        }
    }

    private func entries() throws -> [DiskEntry] {
        try validateRoot()
        return try FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            .compactMap { url in
                guard url.pathExtension == "image" else { return nil }
                try validateFile(url)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true else { return nil }
                return DiskEntry(url: url, bytes: Int64(values.fileSize ?? 0),
                                 lastAccess: values.contentModificationDate ?? .distantPast)
            }
    }

    private func trim(reserving bytes: Int64, replacing: URL?) throws {
        let files = try entries().filter { $0.url.standardizedFileURL != replacing?.standardizedFileURL }
            .sorted { $0.lastAccess < $1.lastAccess }
        var total = files.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in files where total + bytes > Self.diskLimit {
            try validateFile(entry.url)
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    /// Refuse symlink redirects, traversal and the shared Artwork parent.
    /// Every destructive operation validates its exact standardized target.
    private func validateRoot() throws {
        let root = cacheRoot.standardizedFileURL
        guard root.isFileURL, root == cacheRoot,
              root.lastPathComponent == namespaceHash,
              root.deletingLastPathComponent().lastPathComponent == "Artwork",
              root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "dev.fnmusic.mac",
              root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw CacheError.unsafeCachePath
        }
    }

    private func validateFile(_ url: URL) throws {
        try validateRoot()
        let normalized = url.standardizedFileURL
        let name = normalized.deletingPathExtension().lastPathComponent
        guard normalized.deletingLastPathComponent() == cacheRoot,
              normalized.pathExtension == "image", name.count == 64,
              name.allSatisfy({ "0123456789abcdef".contains($0) }),
              normalized.resolvingSymlinksInPath().standardizedFileURL == normalized else {
            throw CacheError.unsafeCachePath
        }
    }

    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
