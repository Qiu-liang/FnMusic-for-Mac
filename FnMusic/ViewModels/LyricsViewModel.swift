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
        guard trackGUID != loadedTrackGUID else { return }
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
        catch { if generation == identity { self.error = error.localizedDescription } }
    }

    func select() {
        guard let lyric = variants.first(where: { $0.guid == selectedGUID }) else {
            parsed = ParsedLyrics(lines: [])
            return
        }
        parsed = LyricParser.parse(lyric)
    }
}
