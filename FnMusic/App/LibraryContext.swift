import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class LibraryContext {
    let client: APIClient
    let music: MusicService
    let playlists: PlaylistService
    let sidebarPlaylists: PlaylistListViewModel
    let browse: BrowseService
    let images: ImageCache
    let search: SearchService
    let player: AudioPlayer
    let queuePanel: QueuePanelState
    let lyricsPanel: LyricsViewModel
    let actions: LibraryActions
    let playlistMutations: PlaylistMutationService
    let artistBrowser: ArtistBrowserViewModel
    let downloads: DownloadViewModel
    var toolbarSearchFocus = UUID()
    var columnVisibility: NavigationSplitViewVisibility = .all
    var rightPanel: RightPanel?
    var navigation: [LibraryRoute] = [] {
        didSet { if !restoringNavigationHistory && navigation != oldValue { forwardRoutes.removeAll() } }
    }
    private var forwardRoutes: [LibraryRoute] = []
    @ObservationIgnored private var restoringNavigationHistory = false
    var canGoForward: Bool { !forwardRoutes.isEmpty }
    var notice: String?

    func resetNavigation() {
        restoringNavigationHistory = true
        navigation = []
        forwardRoutes.removeAll()
        restoringNavigationHistory = false
    }

    func goBack() {
        guard let last = navigation.last else { return }
        restoringNavigationHistory = true
        navigation.removeLast()
        forwardRoutes.append(last)
        restoringNavigationHistory = false
    }

    func goForward() {
        guard let next = forwardRoutes.popLast() else { return }
        restoringNavigationHistory = true
        navigation.append(next)
        restoringNavigationHistory = false
    }

    init(client: APIClient, user: User) {
        let artworkCache = ImageCache(client: client, namespace: client.origin.absoluteString + "|" + user.guid)
        self.client = client
        self.music = MusicService(client: client)
        self.playlists = PlaylistService(client: client)
        self.sidebarPlaylists = PlaylistListViewModel(service: PlaylistService(client: client))
        self.browse = BrowseService(client: client)
        self.search = SearchService(client: client)
        self.player = AudioPlayer(client: client, artworkCache: artworkCache)
        self.queuePanel = QueuePanelState(service: MusicService(client: client))
        self.lyricsPanel = LyricsViewModel(service: LyricsService(client: client))
        self.actions = LibraryActions(favoriteService: FavoriteService(client: client))
        self.playlistMutations = PlaylistMutationService(client: client)
        self.artistBrowser = ArtistBrowserViewModel(music: MusicService(client: client), search: ArtistSearchService(client: client))
        self.downloads = DownloadViewModel(service: TrackDownloadService(client: client))
        self.images = artworkCache
    }
}

enum RightPanel: Equatable {
    case queue
    case lyrics
}

enum LibraryRoute: Hashable {
    case album(Album), artist(Artist), playlist(Playlist)
    case genre(guid: String, name: String)
}
