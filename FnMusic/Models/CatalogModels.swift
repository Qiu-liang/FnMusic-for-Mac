import Foundation

// Wire names deliberately match FnMusicAPI.md. Statistics are optional because
// embedded album/artist references and playlist/list return smaller objects.
struct Track: Codable, Identifiable, Hashable, Sendable {
    let guid: String
    var title: String?
    var coverId: String?
    var year: Int?
    var discNo: Int?
    var trackNo: Int?
    var isrc: String?
    var duration: Double?
    var isCue: Bool?
    var createdAt: Double?
    var updatedAt: Double?
    var album: Album?
    var artists: [Artist]?
    /// Preserve unverified genre payloads; only display names actually returned.
    var genres: [GenreRecord]?
    var audioSpec: AudioSpec?
    var isFavorite: Bool?
    var hasLyric: Bool?
    var score: Double?

    var id: String { guid }
    var displayTitle: String { title?.nilIfEmpty ?? "未知歌曲" }
    var artistText: String { artists?.map(\.displayName).joined(separator: "、").nilIfEmpty ?? "未知艺人" }
    var durationSeconds: Double { max(0, (duration ?? audioSpec?.duration ?? 0) / 1_000) }
    var genreNames: [String] {
        (genres ?? []).compactMap { genre in
            guard case .string(let name) = genre.fields?["name"], !name.isEmpty else { return nil }
            return name
        }
    }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let guid: String
    var name: String?
    var coverId: String?
    var releaseDate: String?
    var barcode: String?
    var createdAt: Double?
    var updatedAt: Double?
    var artists: [Artist]?
    var trackCount: Int?
    var score: Double?

    var id: String { guid }
    var displayName: String { name?.nilIfEmpty ?? "未知专辑" }
    var artistText: String { artists?.map(\.displayName).joined(separator: "、").nilIfEmpty ?? "未知艺人" }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let guid: String
    var name: String?
    var coverId: String?
    var createdAt: Double?
    var updatedAt: Double?
    var trackCount: Int?
    var albumCount: Int?
    var score: Double?

    var id: String { guid }
    var displayName: String { name?.nilIfEmpty ?? "未知艺人" }
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let guid: String
    var name: String?
    var coverId: String?
    var createdAt: Double?
    var updatedAt: Double?
    var trackCount: Int?
    var score: Double?

    var id: String { guid }
    var displayName: String { name?.nilIfEmpty ?? "未命名歌单" }
}

struct AudioSpec: Codable, Hashable, Sendable {
    var bitDepth: Int?
    var sampleRate: Double?
    var channel: Int?
    var bitrate: Double?
    var codec: String?
    var container: String?
    var format: String?
    var duration: Double?
    /// Server-local metadata. Never use this value to construct a client URL.
    var path: String?
    var size: Int64?
    var `extension`: String?
}

struct TrackMetadata: Codable, Sendable {
    let track: Track
    var audioSpec: AudioSpec?
}

struct Page<Item: Codable & Sendable>: Codable, Sendable {
    var list: [Item]
    var total: Int?
    var sort: String?
}

struct SearchResult: Sendable {
    var tracks: [Track] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Double {
    var playbackTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let seconds = Int(min(self, 359_999))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
