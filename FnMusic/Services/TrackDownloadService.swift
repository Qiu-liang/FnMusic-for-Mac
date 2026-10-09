import Foundation
import Darwin

protocol TrackDownloadServiceProtocol: Sendable {
    func suggestedFilename(for track: Track) async throws -> String
    func download(_ track: Track, to destination: URL,
                  progress: @escaping @Sendable (Double) async -> Void) async throws
}

/// Only original bytes from the documented APIClient transport; never uploads or transcodes.
/// The destination must have a one-use DownloadSaveAuthorization from NSSavePanel's .OK.
struct TrackDownloadService: TrackDownloadServiceProtocol {
    typealias Stream = @Sendable (String, Int64, Int) async throws -> MediaChunk
    private let client: APIClient
    private let stream: Stream
    private static let chunkSize = 512 * 1024

    init(client: APIClient) {
        self.client = client
        self.stream = { try await client.stream(guid: $0, offset: $1, length: $2) }
    }

    /// Test seam for malformed MediaChunk invariants; production always uses init(client:).
    init(client: APIClient, stream: @escaping Stream) {
        self.client = client
        self.stream = stream
    }

    private func metadata(for track: Track) async throws -> TrackMetadata {
        guard track.isCue != true else { throw TrackDownloadError.cueTrack }
        try Task.checkCancellation()
        let metadata: TrackMetadata = try await client.value(
            APIRequest(path: "/track/metadata", query: ["guid": track.guid]))
        guard metadata.track.guid == track.guid else { throw APIError.decoding }
        guard metadata.track.isCue != true else { throw TrackDownloadError.cueTrack }
        return metadata
    }

    func suggestedFilename(for track: Track) async throws -> String {
        let metadata = try await metadata(for: track)
        let spec = metadata.audioSpec ?? metadata.track.audioSpec ?? track.audioSpec
        // Only FLAC/MP3 Range samples are confirmed in FnMusicAPI.md. An extension
        // is a naming hint, NOT a guarantee of full-file download or native playback.
        // Never inspect AudioSpec.path, even as a fallback filename/extension.
        let hints = [spec?.extension, spec?.container, spec?.format, spec?.codec]
        let ext = hints.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .compactMap { hint -> String? in
                switch hint {
                case "flac", "audio/flac": return "flac"
                case "mp3", "mpeg", "audio/mpeg": return "mp3"
                default: return nil
                }
            }.first ?? "audio"
        return Self.safeTitle(track.title ?? metadata.track.title ?? "未知歌曲") + "." + ext
    }

    private static func safeTitle(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map {
            forbidden.contains($0) ? Unicode.Scalar("_") : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Bound UTF-8 bytes, not just characters (APFS filename limit). Leave room for extension.
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "未知歌曲" : result
    }

    func download(_ track: Track, to destination: URL,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        try Task.checkCancellation()
        guard track.isCue != true else { throw TrackDownloadError.cueTrack }
        let ticket = try await DownloadFileAccess.shared.begin(destination)
        do {
            _ = try await metadata(for: track) // Detail can reveal CUE omitted from a list item.
            var offset: Int64 = 0
            var total: Int64?
            await progress(0)
            repeat {
                try Task.checkCancellation()
                let length = total.map { Int(min(Int64(Self.chunkSize), $0 - offset)) } ?? Self.chunkSize
                let chunk = try await stream(track.guid, offset, length)
                try Task.checkCancellation()
                guard chunk.supportsRanges, chunk.rangeStart == offset, chunk.totalLength > offset,
                      total == nil || total == chunk.totalLength,
                      !chunk.data.isEmpty, chunk.data.count <= length,
                      Int64(chunk.data.count) == min(Int64(length), chunk.totalLength - offset) else {
                    throw APIError.invalidRange
                }
                let (next, overflow) = offset.addingReportingOverflow(Int64(chunk.data.count))
                guard !overflow, next > offset, next <= chunk.totalLength else { throw APIError.invalidRange }
                total = chunk.totalLength
                try await DownloadFileAccess.shared.append(chunk.data, to: ticket)
                offset = next
                // Reserve 1.0 for a successfully committed file.
                await progress(min(0.999, Double(offset) / Double(chunk.totalLength)))
            } while offset < (total ?? 0)
            try Task.checkCancellation()
            try await DownloadFileAccess.shared.commit(ticket)
            await progress(1)
        } catch {
            await DownloadFileAccess.shared.abort(ticket)
            throw error
        }
    }
}

enum TrackDownloadError: Error, LocalizedError, Equatable {
    case cueTrack, unsafeDestination, authorizationRequired, destinationChanged, busy, fileIO

    var errorDescription: String? {
        switch self {
        case .cueTrack: "CUE 虚拟分轨的原文件下载行为尚未验证，暂不支持下载。"
        case .unsafeDestination: "保存位置不安全：请选择普通文件，不能使用目录或符号链接。"
        case .authorizationRequired: "请先通过保存面板明确选择目标文件并确认覆盖。"
        case .destinationChanged: "保存位置在下载期间发生变化，未覆盖目标文件。"
        case .busy: "此保存位置已有下载正在进行，请稍后重试。"
        case .fileIO: "无法安全写入下载文件，请检查保存位置和可用空间。"
        }
    }
}

/// Internal bridge for the panel, not a blanket permission inferred from an existing file.
/// Call only after NSSavePanel .OK (including its standard replacement confirmation).
/// Tests may simulate that explicit user choice inside their own unique temporary directory.
/// A custom TrackDownloadServiceProtocol implementation must honor the same destination contract.
enum DownloadSaveAuthorization {
    static func recordPanelSelection(_ destination: URL) async throws -> UUID {
        try await DownloadFileAccess.shared.authorize(destination)
    }

    static func revoke(_ token: UUID) async {
        await DownloadFileAccess.shared.revoke(token)
    }
}

/// Actor-isolated synchronous disk I/O never runs on MainActor. All service instances
/// share target leases; directory descriptors pin writes/rename to the validated parent.
private actor DownloadFileAccess {
    static let shared = DownloadFileAccess()

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
        }
        func sameFile(as other: Identity) -> Bool { device == other.device && inode == other.inode }
    }
    private struct Grant {
        let token: UUID
        let target: URL
        let original: Identity?
    }
    private struct Transfer {
        let grant: Grant
        let parent: URL
        let parentIdentity: Identity
        let directoryFD: Int32
        let temporary: URL
        let temporaryIdentity: Identity
        let handle: FileHandle
    }
    private var grants: [String: Grant] = [:]
    private var transfers: [UUID: Transfer] = [:]
    private var busyPaths: Set<String> = []

    private func normalized(_ url: URL) throws -> URL {
        guard url.isFileURL, url.baseURL == nil, url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.contains("\0"),
              !url.pathComponents.contains("..") else { throw TrackDownloadError.unsafeDestination }
        let target = url.standardizedFileURL
        guard target.path != "/", !target.lastPathComponent.isEmpty,
              target.resolvingSymlinksInPath().path == target.path else {
            throw TrackDownloadError.unsafeDestination
        }
        let parent = target.deletingLastPathComponent()
        var parentStat = stat()
        guard lstat(parent.path, &parentStat) == 0,
              parentStat.st_mode & S_IFMT == S_IFDIR else { throw TrackDownloadError.unsafeDestination }
        _ = try regularIdentity(target)
        return target
    }

    private func regularIdentity(_ url: URL) throws -> Identity? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            guard errno == ENOENT else { throw TrackDownloadError.fileIO }
            return nil
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw TrackDownloadError.unsafeDestination }
        return Identity(value)
    }

    func authorize(_ destination: URL) throws -> UUID {
        let target = try normalized(destination)
        guard !busyPaths.contains(target.path), grants[target.path] == nil else { throw TrackDownloadError.busy }
        let token = UUID()
        grants[target.path] = Grant(token: token, target: target, original: try regularIdentity(target))
        return token
    }

    func revoke(_ token: UUID) {
        if let path = grants.first(where: { $0.value.token == token })?.key { grants[path] = nil }
    }

    func begin(_ destination: URL) throws -> UUID {
        try Task.checkCancellation()
        let target = try normalized(destination)
        guard !busyPaths.contains(target.path) else { throw TrackDownloadError.busy }
        guard let grant = grants.removeValue(forKey: target.path) else { throw TrackDownloadError.authorizationRequired }
        guard try regularIdentity(target) == grant.original else { throw TrackDownloadError.destinationChanged }
        let parent = target.deletingLastPathComponent()
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw TrackDownloadError.fileIO }
        var parentStat = stat()
        guard fstat(directoryFD, &parentStat) == 0 else {
            close(directoryFD)
            throw TrackDownloadError.fileIO
        }
        let ticket = UUID()
        let temporary = parent.appendingPathComponent(".fnmusic-download-\(ticket.uuidString).partial")
        let fd = openat(directoryFD, temporary.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { close(directoryFD); throw TrackDownloadError.fileIO }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var tempStat = stat()
        guard fstat(fd, &tempStat) == 0 else {
            // No verified identity: deliberately do not unlink an unverified path.
            try? handle.close(); close(directoryFD)
            throw TrackDownloadError.fileIO
        }
        transfers[ticket] = Transfer(grant: grant, parent: parent, parentIdentity: Identity(parentStat),
                                     directoryFD: directoryFD, temporary: temporary,
                                     temporaryIdentity: Identity(tempStat), handle: handle)
        busyPaths.insert(target.path)
        return ticket
    }

    /// Check resolved absolute target + UUID temporary path BEFORE any rename/unlink.
    /// Refuse symlinks and a replaced parent/temp inode; no recursive deletion ever.
    private func verify(_ transfer: Transfer, ticket: UUID) throws {
        let target = try normalized(transfer.grant.target)
        let expected = transfer.parent.appendingPathComponent(".fnmusic-download-\(ticket.uuidString).partial")
        guard target.path == transfer.grant.target.path,
              target.deletingLastPathComponent().path == transfer.parent.path,
              transfer.temporary.path == expected.path, expected.path != target.path,
              try normalized(expected).path == expected.path else { throw TrackDownloadError.unsafeDestination }
        var parentStat = stat()
        var tempStat = stat()
        guard lstat(transfer.parent.path, &parentStat) == 0,
              Identity(parentStat).sameFile(as: transfer.parentIdentity),
              fstatat(transfer.directoryFD, expected.lastPathComponent, &tempStat, AT_SYMLINK_NOFOLLOW) == 0,
              tempStat.st_mode & S_IFMT == S_IFREG,
              Identity(tempStat).sameFile(as: transfer.temporaryIdentity) else {
            throw TrackDownloadError.destinationChanged
        }
    }

    func append(_ bytes: Data, to ticket: UUID) throws {
        try Task.checkCancellation()
        guard let transfer = transfers[ticket] else { throw TrackDownloadError.fileIO }
        try verify(transfer, ticket: ticket)
        try transfer.handle.write(contentsOf: bytes)
    }

    func commit(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard let transfer = transfers[ticket] else { throw TrackDownloadError.fileIO }
        try transfer.handle.synchronize()
        try transfer.handle.close()
        try verify(transfer, ticket: ticket)
        guard try regularIdentity(transfer.grant.target) == transfer.grant.original else {
            throw TrackDownloadError.destinationChanged
        }
        try Task.checkCancellation()
        let result: Int32
        if transfer.grant.original == nil {
            // Atomic no-clobber if a new file appeared since the user's selection.
            result = renameatx_np(transfer.directoryFD, transfer.temporary.lastPathComponent,
                                  transfer.directoryFD, transfer.grant.target.lastPathComponent, UInt32(RENAME_EXCL))
        } else {
            // Explicit .OK replacement grant, unchanged original identity, same directory.
            // POSIX rename is atomic: failures leave the old destination intact.
            result = renameat(transfer.directoryFD, transfer.temporary.lastPathComponent,
                              transfer.directoryFD, transfer.grant.target.lastPathComponent)
        }
        guard result == 0 else { throw TrackDownloadError.fileIO }
        finish(ticket, transfer: transfer)
    }

    func abort(_ ticket: UUID) {
        guard let transfer = transfers[ticket] else { return }
        try? transfer.handle.close()
        if (try? verify(transfer, ticket: ticket)) != nil {
            // Only our validated UUID temporary inode, never the destination/original.
            _ = unlinkat(transfer.directoryFD, transfer.temporary.lastPathComponent, 0)
        }
        // If validation fails, prefer a stranded temp over deleting someone else's file.
        finish(ticket, transfer: transfer)
    }

    private func finish(_ ticket: UUID, transfer: Transfer) {
        close(transfer.directoryFD)
        transfers[ticket] = nil
        busyPaths.remove(transfer.grant.target.path)
    }
}
