import Foundation
import AVFoundation
import Observation

@MainActor @Observable
final class AudioPlayer {
    let queue = QueueManager()
    var isPlaying = false
    var isLoading = false
    var elapsed: Double = 0
    var duration: Double = 0
    var error: String?
    var volume: Double = 0.7 {
        didSet { player.volume = Float(min(1, max(0, volume))) }
    }
    var currentTrack: Track? { queue.current }
    /// Read-only access for AVKit's public native AirPlay routing control.
    var routePickerPlayer: AVPlayer { player }

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var resourceLoader: AudioResourceLoader?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPlayID = UUID()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var media: MediaSession?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var wantsPlayback = false

    init(client: APIClient, artworkCache: ImageCache) {
        self.client = client
        if let stored = UserDefaults.standard.object(forKey: "defaultVolume") as? Double { volume = min(1, max(0, stored)) }
        queue.repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "defaultRepeat") ?? "off") ?? .off
        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.elapsed = max(0, seconds) }
                if let length = self.player.currentItem?.duration.seconds, length.isFinite, length > 0 { self.duration = length }
                self.isPlaying = self.player.rate > 0
                self.isLoading = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.media?.update(player: self)
            }
        }
        media = MediaSession(player: self, artworkCache: artworkCache)
    }

    @discardableResult
    func beginPendingPlay() -> UUID {
        cancelBackfill()
        let token = UUID()
        pendingPlayID = token
        return token
    }

    func isCurrentPendingPlay(_ id: UUID) -> Bool {
        pendingPlayID == id
    }

    func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
    }

    func waitForBackfill() async {
        await backfillTask?.value
    }

    func play(_ track: Track, in tracks: [Track]? = nil,
              continuation: PagedTrackContinuation? = nil,
              onBackfillError: (@MainActor (Error) -> Void)? = nil) {
        pendingPlayID = UUID()
        cancelBackfill()
        queue.replace(with: tracks ?? [track], startAt: track.guid)
        let expectedSessionID = queue.sessionID
        prepareCurrent()

        guard let continuation else { return }
        var seen = continuation.loadedGUIDs
        seen.formUnion(queue.tracks.map(\.guid))
        backfillTask = Task { [weak self] in
            guard let self else { return }
            var page = continuation.startPage
            var pagesLoaded = 0
            var hasMore = true
            while hasMore, pagesLoaded < continuation.maxPages,
                  !Task.isCancelled, self.queue.sessionID == expectedSessionID {
                do {
                    let response = try await continuation.fetchPage(page)
                    try Task.checkCancellation()
                    guard self.queue.sessionID == expectedSessionID else { return }
                    let added = response.list.filter { seen.insert($0.guid).inserted }
                    let matching = continuation.filter.map { added.filter($0) } ?? added
                    if !matching.isEmpty {
                        self.queue.append(contentsOf: matching)
                    }
                    if added.isEmpty || response.list.isEmpty {
                        hasMore = false
                    } else if let total = response.total {
                        hasMore = seen.count < total
                    } else {
                        hasMore = response.list.count >= MusicService.pageSize
                    }
                    page += 1
                    pagesLoaded += 1
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.queue.sessionID == expectedSessionID else { return }
                    onBackfillError?(error)
                    return
                }
            }
        }
    }

    func playQueueIndex(_ index: Int) {
        pendingPlayID = UUID()
        guard queue.select(index: index) != nil else { return }
        prepareCurrent()
    }

    func removeQueueEntry(at index: Int) {
        let wasCurrent = queue.index == index
        let wasPlaying = wantsPlayback
        queue.remove(at: index)
        if queue.tracks.isEmpty {
            cancelBackfill()
        }
        guard wasCurrent else { return }
        preparation?.cancel()
        generation = UUID()
        resourceLoader?.cancelAll()
        resourceLoader = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        removeItemNotifications()
        elapsed = 0
        duration = currentTrack?.durationSeconds ?? 0
        isPlaying = false
        isLoading = false
        wantsPlayback = false
        if wasPlaying, currentTrack != nil { prepareCurrent() }
        media?.update(player: self)
    }

    func toggle() {
        if isPlaying || wantsPlayback { pause() } else { resume() }
    }

    func pause() {
        pendingPlayID = UUID()
        wantsPlayback = false
        player.pause()
        isPlaying = false
        media?.update(player: self)
    }

    func resume() {
        guard currentTrack != nil else { return }
        if player.currentItem == nil || error != nil { prepareCurrent(); return }
        wantsPlayback = true
        if duration > 0, elapsed >= duration - 0.05 { seek(to: 0) }
        player.play()
        media?.update(player: self)
    }

    func next(automatic: Bool = false) {
        if automatic, UserDefaults.standard.object(forKey: "autoAdvance") as? Bool == false { pause(); return }
        guard queue.nextForPlayback(automatic: automatic) != nil else {
            pause()
            return
        }
        prepareCurrent()
    }

    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        guard queue.previous() != nil else { seek(to: 0); return }
        prepareCurrent()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        elapsed = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
        media?.update(player: self)
    }

    private func prepareCurrent() {
        preparation?.cancel()
        resourceLoader?.cancelAll()
        itemObservation = nil
        removeItemNotifications()
        player.pause()
        player.replaceCurrentItem(with: nil)
        let identity = UUID()
        generation = identity
        elapsed = 0
        duration = currentTrack?.durationSeconds ?? 0
        error = nil
        isLoading = true
        isPlaying = false
        wantsPlayback = true
        guard let track = currentTrack else { isLoading = false; return }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                // CUE stream boundaries have no success sample. Do not silently
                // play an entire source file as if it were the selected subtrack.
                guard track.isCue != true else {
                    throw APIError.unavailable("CUE 虚拟分轨播放尚未验证，暂不播放此曲目。")
                }
                let metadata: TrackMetadata = try await client.value(APIRequest(path: "/track/metadata", query: ["guid": track.guid], cachePolicy: .memory(maxAge: 15)))
                try Task.checkCancellation()
                guard generation == identity else { return }
                guard metadata.track.isCue != true else { throw APIError.unavailable("CUE 虚拟分轨播放尚未验证。") }
                let loader = AudioResourceLoader(client: client, guid: track.guid, audioSpec: metadata.audioSpec ?? metadata.track.audioSpec ?? track.audioSpec)
                let asset = try loader.makeAsset()
                resourceLoader = loader
                let item = AVPlayerItem(asset: asset)
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.itemStatusChanged(identity: identity) }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == identity else { return }
                        self.next(automatic: true)
                    }
                }
                failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == identity else { return }
                        self.fail(self.resourceLoader?.failure ?? APIError.unsupportedAudio)
                    }
                }
                player.replaceCurrentItem(with: item)
                if wantsPlayback { player.play() }
                media?.update(player: self)
            } catch is CancellationError { }
            catch { if generation == identity { fail(error) } }
        }
    }

    private func itemStatusChanged(identity: UUID) {
        guard identity == generation, let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            isLoading = false
            if item.duration.seconds.isFinite { duration = item.duration.seconds }
            if wantsPlayback { player.play() }
        case .failed: fail(resourceLoader?.failure ?? APIError.unsupportedAudio)
        default: break
        }
    }

    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        itemObservation = nil
        removeItemNotifications()
        resourceLoader?.cancelAll()
        resourceLoader = nil
        player.replaceCurrentItem(with: nil)
        isLoading = false
        pause()
    }

    private func removeItemNotifications() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
    }

    /// Called before discarding a signed-in context. Stops network, releases
    /// observers and removes private metadata from system media controls.
    func shutdown() {
        pendingPlayID = UUID()
        cancelBackfill()
        preparation?.cancel()
        preparation = nil
        generation = UUID()
        pause()
        resourceLoader?.cancelAll()
        resourceLoader = nil
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeItemNotifications()
        media?.invalidate()
        media = nil
        queue.clear()
    }
}
