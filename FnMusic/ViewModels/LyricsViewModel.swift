import Foundation
import Observation

@MainActor @Observable
final class LyricsViewModel {
    var parsed = ParsedLyrics(lines: [])
    var loading = false
    var error: String?
    var variants: [Lyric] = []
    var selectedGUID: String?
    private var loadedTrackGUID: String?
    private let service: any LyricsServiceProtocol
    private var generation = UUID()

    init(service: any LyricsServiceProtocol) { self.service = service }

    func load(trackGUID: String?) async {
        // Only skip a reload of a track that has already loaded successfully.
        // A nil load must still invalidate an in-flight request and bump the
        // generation; otherwise a late response can repopulate cleared state.
        if let trackGUID, trackGUID == loadedTrackGUID { return }
        let identity = UUID()
        generation = identity
        loadedTrackGUID = nil
        parsed = ParsedLyrics(lines: [])
        variants = []
        error = nil
        selectedGUID = nil
        loading = false
        guard let trackGUID else { return }
        loading = true
        defer { if identity == generation { loading = false } }
        do {
            let response = try await service.lyrics(trackGUID: trackGUID)
            try Task.checkCancellation()
            guard generation == identity else { return }
            variants = response.list
            selectedGUID = response.selected?.guid
            select()
            loadedTrackGUID = trackGUID
        } catch is CancellationError { }
        catch {
            guard generation == identity, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func select() {
        guard let lyric = variants.first(where: { $0.guid == selectedGUID }) else {
            parsed = ParsedLyrics(lines: [])
            return
        }
        parsed = LyricParser.parse(lyric)
    }
}
