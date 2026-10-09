import Foundation
import Observation

enum ArtistScope: Hashable, Sendable {
    case all
    case collaborations
    case artist(Artist)

    var id: String {
        switch self {
        case .all: "all"
        case .collaborations: "collaborations"
        case .artist(let artist): "artist:\(artist.guid)"
        }
    }

    var title: String {
        switch self {
        case .all: "所有艺人"
        case .collaborations: "合唱艺人"
        case .artist(let artist): artist.displayName
        }
    }
}

/// An album is only a grouping/metadata reference, never a source of extra tracks.
/// Album GUIDs (not names) establish identity; missing albums share one explicit
/// unclassified section. Sections retain their first-seen order across pages.
struct ArtistAlbumSection: Identifiable, Sendable {
    let id: String
    var album: Album?
    var tracks: [Track]

    var title: String { album?.displayName ?? "未归类" }
    var coverId: String? {
        album?.coverId?.nilIfEmpty ?? tracks.lazy.compactMap { $0.coverId?.nilIfEmpty }.first
    }
    var subtitle: String {
        let trackYears = Set(tracks.compactMap(\.year).filter { $0 > 0 }).sorted()
        let albumYear = album?.releaseDate.flatMap { date -> String? in
            let prefix = String(date.prefix(4))
            guard prefix.count == 4, let year = Int(prefix), year > 0 else { return nil }
            return prefix
        }
        var parts: [String] = []
        if !trackYears.isEmpty {
            parts.append(trackYears.map(String.init).joined(separator: "、"))
        } else if let albumYear {
            parts.append(albumYear)
        }
        // Only names actually supplied by the response are exposed by genreNames.
        var seenGenres = Set<String>()
        let genres = tracks.flatMap(\.genreNames).filter {
            !$0.isEmpty && seenGenres.insert($0).inserted
        }
        if !genres.isEmpty { parts.insert(genres.joined(separator: "、"), at: 0) }
        parts.append("\(tracks.count) 首歌曲")
        return parts.joined(separator: " · ")
    }
}

@MainActor @Observable
final class ArtistBrowserViewModel {
    var query = "" {
        didSet { if query != oldValue { invalidateDirectory() } }
    }
    var sort = "name,asc" {
        didSet { if sort != oldValue { invalidateDirectory() } }
    }
    var selectedScope: ArtistScope = .all {
        didSet {
            guard selectedScope.id != oldValue.id else { return }
            hasMadeSelection = true
            if !restoringHistory {
                backHistory.append(oldValue)
                forwardHistory.removeAll()
            }
            resetDetail()
        }
    }

    private(set) var artists: [Artist] = []
    private(set) var directoryLoading = false
    private(set) var directoryError: String?
    private(set) var directoryHasMore = true
    private(set) var directoryTotal: Int?
    private(set) var hasDirectorySnapshot = false

    private(set) var detailArtist: Artist?
    private(set) var sections: [ArtistAlbumSection] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var warning: String?
    private(set) var hasMoreTracks = true
    /// Server candidate count; in collaborations mode this is NOT a duet total.
    private(set) var totalTracks: Int?
    /// Unique server tracks examined, including tracks excluded by the filter.
    private(set) var scannedTracks = 0

    var loadedTracks: [Track] { sections.flatMap(\.tracks) }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    /// Filtering is factual but partial: only the loaded library pages are known.
    var isPartialCollaborationFilter: Bool { selectedScope == .collaborations }

    @ObservationIgnored private let music: any MusicServiceProtocol
    @ObservationIgnored private let search: any ArtistSearchServiceProtocol
    @ObservationIgnored private var directoryTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    private var directoryGeneration = UUID()
    private var detailGeneration = UUID()
    private var directoryPage = 1
    private var trackPage = 1
    private var metadataPage = 1
    private var metadataHasMore = true
    private var metadataIncomplete = false
    private var metadataFailed = false
    private var artistFailed = false
    private var metadata: [String: Album] = [:]
    private var seenTrackGUIDs = Set<String>()
    private var hasMadeSelection = false
    private var backHistory: [ArtistScope] = []
    private var forwardHistory: [ArtistScope] = []
    private var restoringHistory = false

    init(music: any MusicServiceProtocol, search: any ArtistSearchServiceProtocol) {
        self.music = music
        self.search = search
    }

    // MARK: Directory

    /// Re-entering the page retains loaded pages and the selected artist. Explicit
    /// refresh, search and sort changes still request a new authoritative snapshot.
    func ensureDirectory() async {
        if !hasDirectorySnapshot { await reloadDirectory() }
    }

    func reloadDirectory() async {
        guard !Task.isCancelled else { return }
        invalidateDirectory()
        artists = []
        directoryPage = 1
        directoryTotal = nil
        directoryHasMore = true
        directoryError = nil
        await startDirectoryRequest(debounce: !query.isEmpty)
    }

    func loadMoreArtists() async {
        guard !Task.isCancelled, !directoryLoading, directoryHasMore,
              query.isEmpty else { return }
        await startDirectoryRequest(debounce: false)
    }

    private func startDirectoryRequest(debounce: Bool) async {
        let generation = directoryGeneration
        let requestedQuery = query
        let requestedSort = sort
        let page = directoryPage
        directoryLoading = true
        directoryError = nil
        let task = Task { [self] in
            defer {
                if generation == directoryGeneration { directoryLoading = false }
            }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                let response: Page<Artist>
                if requestedQuery.isEmpty {
                    response = try await music.artists(page: page, sort: requestedSort)
                } else {
                    response = try await search.artists(query: requestedQuery)
                }
                try Task.checkCancellation()
                guard generation == directoryGeneration else { return }
                var seen = Set(artists.map(\.guid))
                let added = response.list.filter { seen.insert($0.guid).inserted }
                artists.append(contentsOf: added)
                hasDirectorySnapshot = true
                directoryTotal = response.total
                directoryHasMore = requestedQuery.isEmpty && Self.hasNextPage(
                    response, addedCount: added.count, uniqueCount: artists.count
                )
                directoryPage += 1
                // An empty first response does not consume the one-time default.
                // Any explicit user selection, including .all, does consume it.
                if !hasMadeSelection, let first = artists.first { selectArtist(first) }
            } catch is CancellationError {
                // Cancellation is a lifecycle event, not an error banner.
            } catch {
                if generation == directoryGeneration && !Task.isCancelled {
                    directoryError = error.localizedDescription
                }
            }
        }
        directoryTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func invalidateDirectory() {
        hasDirectorySnapshot = false
        directoryGeneration = UUID()
        directoryTask?.cancel()
        directoryTask = nil
        directoryLoading = false
    }

    // MARK: Selection and navigation

    func select(_ scope: ArtistScope) {
        hasMadeSelection = true
        selectedScope = scope
    }

    func selectArtist(_ artist: Artist) { select(.artist(artist)) }

    func back() {
        guard let scope = backHistory.popLast() else { return }
        forwardHistory.append(selectedScope)
        restoringHistory = true
        selectedScope = scope
        restoringHistory = false
    }

    func forward() {
        guard let scope = forwardHistory.popLast() else { return }
        backHistory.append(selectedScope)
        restoringHistory = true
        selectedScope = scope
        restoringHistory = false
    }

    /// Also call on view disappearance to cancel button-triggered pagination.
    /// SwiftUI .task cancellation is propagated to the owned request automatically.
    func invalidate() {
        invalidateDirectory()
        invalidateDetail()
    }

    // MARK: Track pages and optional metadata

    func loadDetail() async {
        guard !Task.isCancelled else { return }
        resetDetail()
        await startDetailRequest(includeArtist: true)
    }

    func loadMoreTracks() async {
        guard !Task.isCancelled, !loading, hasMoreTracks else { return }
        await startDetailRequest(includeArtist: false)
    }

    private func startDetailRequest(includeArtist: Bool) async {
        let generation = detailGeneration
        let scope = selectedScope
        let source: TrackSource
        let artistGUID: String?
        if case .artist(let artist) = scope {
            source = .artist(artist.guid)
            artistGUID = artist.guid
        } else {
            source = .library
            artistGUID = nil
        }
        let page = trackPage
        loading = true
        error = nil
        let task = Task { [self] in
            defer { if generation == detailGeneration { loading = false } }
            do {
                try Task.checkCancellation()
                let response = try await music.tracks(page: page, sort: source.defaultSort, source: source)
                try Task.checkCancellation()
                guard generation == detailGeneration else { return }
                let added = response.list.filter { seenTrackGUIDs.insert($0.guid).inserted }
                scannedTracks = seenTrackGUIDs.count
                totalTracks = response.total
                hasMoreTracks = Self.hasNextPage(response, addedCount: added.count, uniqueCount: scannedTracks)
                trackPage += 1
                let displayed = scope == .collaborations ? added.filter(Self.isCollaboration) : added
                appendTracks(displayed)
                updateWarning()
            } catch is CancellationError {
                return
            } catch {
                if generation == detailGeneration && !Task.isCancelled {
                    self.error = error.localizedDescription
                }
                return
            }

            // Publish successful tracks before attempting optional enrichment.
            // Never fetch album tracks: that would mix unrelated album artists in.
            await loadAlbumMetadata(artistGUID: artistGUID, generation: generation)
            guard generation == detailGeneration, !Task.isCancelled else { return }
            if includeArtist, let artistGUID {
                do {
                    let artist = try await music.artist(guid: artistGUID)
                    try Task.checkCancellation()
                    guard generation == detailGeneration else { return }
                    detailArtist = artist
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == detailGeneration, !Task.isCancelled else { return }
                    artistFailed = true
                }
            }
            updateWarning()
        }
        detailTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadAlbumMetadata(artistGUID: String?, generation: UUID) async {
        guard metadataHasMore, generation == detailGeneration, !Task.isCancelled else { return }
        do {
            // At most one metadata page per requested track page, never list-all
            // or an eager drain. Embedded album data remains usable meanwhile.
            let response = try await music.albums(page: metadataPage, sort: "newTrackAddedAt,desc", artistGUID: artistGUID)
            try Task.checkCancellation()
            guard generation == detailGeneration else { return }
            var addedCount = 0
            for album in response.list {
                if metadata[album.guid] == nil { addedCount += 1 }
                metadata[album.guid] = Self.merging(album, fallback: metadata[album.guid])
            }
            metadataHasMore = Self.hasNextPage(response, addedCount: addedCount, uniqueCount: metadata.count)
            // A repeated page stops pagination but must not claim completeness.
            metadataIncomplete = metadataHasMore || (response.total.map { metadata.count < $0 } ?? false)
            metadataPage += 1
            metadataFailed = false
            for index in sections.indices {
                if let album = sections[index].album, let enriched = metadata[album.guid] {
                    sections[index].album = Self.merging(enriched, fallback: album)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == detailGeneration, !Task.isCancelled else { return }
            metadataFailed = true
        }
        updateWarning()
    }

    private func appendTracks(_ tracks: [Track]) {
        var sectionIndices = Dictionary(uniqueKeysWithValues: sections.enumerated().map { ($0.element.id, $0.offset) })
        for track in tracks {
            let id = track.album.map { "album:\($0.guid)" } ?? "unclassified"
            if let index = sectionIndices[id] {
                sections[index].tracks.append(track)
                if let album = track.album {
                    sections[index].album = Self.merging(sections[index].album ?? album, fallback: album)
                }
            } else {
                let album = track.album.map { Self.merging(metadata[$0.guid] ?? $0, fallback: $0) }
                sectionIndices[id] = sections.count
                sections.append(ArtistAlbumSection(id: id, album: album, tracks: [track]))
            }
        }
        for index in sections.indices {
            // Explicit offset tie-break keeps equal/missing numbers stable even
            // when a subsequent page inserts tracks into an existing section.
            sections[index].tracks = sections[index].tracks.enumerated().sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element
                if left.discNo != right.discNo { return Self.numberPrecedes(left.discNo, right.discNo) }
                if left.trackNo != right.trackNo { return Self.numberPrecedes(left.trackNo, right.trackNo) }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    private func updateWarning() {
        var messages: [String] = []
        if isPartialCollaborationFilter {
            messages.append("合唱仅按已扫描歌曲中的不同艺人 GUID 筛选，不代表全库结果。")
        }
        if metadataFailed { messages.append("专辑资料读取失败，已保留成功读取的歌曲。") }
        if artistFailed { messages.append("艺人资料读取失败，已保留歌曲及目录中的艺人资料。") }
        if metadataIncomplete { messages.append("专辑资料尚未完整加载，分类信息可能不完整。") }
        if sections.contains(where: { $0.album == nil || $0.album?.name?.nilIfEmpty == nil }) {
            messages.append("部分歌曲缺少专辑资料，已保留在未归类或未知专辑中。")
        }
        warning = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func invalidateDetail() {
        detailGeneration = UUID()
        detailTask?.cancel()
        detailTask = nil
        loading = false
    }

    private func resetDetail() {
        invalidateDetail()
        if case .artist(let artist) = selectedScope { detailArtist = artist } else { detailArtist = nil }
        sections = []
        error = nil
        warning = nil
        hasMoreTracks = true
        totalTracks = nil
        scannedTracks = 0
        trackPage = 1
        metadataPage = 1
        metadataHasMore = true
        metadataIncomplete = false
        metadataFailed = false
        artistFailed = false
        metadata = [:]
        seenTrackGUIDs = []
    }

    private static func hasNextPage<T>(_ response: Page<T>, addedCount: Int, uniqueCount: Int) -> Bool {
        addedCount > 0 && !response.list.isEmpty &&
            (response.total.map { uniqueCount < $0 } ?? (response.list.count >= MusicService.pageSize))
    }

    private static func isCollaboration(_ track: Track) -> Bool {
        Set((track.artists ?? []).map(\.guid).filter { !$0.isEmpty }).count > 1
    }

    private static func numberPrecedes(_ lhs: Int?, _ rhs: Int?) -> Bool {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)): left < right
        case (.some, .none): true
        default: false
        }
    }

    private static func merging(_ preferred: Album, fallback: Album?) -> Album {
        guard let fallback else { return preferred }
        var album = preferred
        album.name = preferred.name?.nilIfEmpty ?? fallback.name
        album.coverId = preferred.coverId?.nilIfEmpty ?? fallback.coverId
        album.releaseDate = preferred.releaseDate?.nilIfEmpty ?? fallback.releaseDate
        album.barcode = preferred.barcode ?? fallback.barcode
        album.createdAt = preferred.createdAt ?? fallback.createdAt
        album.updatedAt = preferred.updatedAt ?? fallback.updatedAt
        album.artists = preferred.artists ?? fallback.artists
        album.trackCount = preferred.trackCount ?? fallback.trackCount
        album.score = preferred.score ?? fallback.score
        return album
    }
}
