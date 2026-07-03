//
// PlaylistManager class
//
// This class handles all the Playlist operations done by the app, note that this file only
// contains core methods, the domain-specific logic is spread across extension files within this
// directory where each file is prefixed with `PM`.
//

import Foundation

class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var currentPlaylist: Playlist?
    @Published var isShuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var currentQueue: [Track] = []
    @Published var currentQueueIndex: Int = -1
    @Published var currentQueueSource: QueueSource = .library
    @Published var showingCreatePlaylistModal = false
    @Published var tracksToAddToNewPlaylist: [Track] = []
    @Published var newPlaylistName = ""
    // Smart playlist editor: presented for both creating (toEdit == nil) and editing.
    @Published var showingSmartPlaylistEditor = false
    @Published var smartPlaylistToEdit: Playlist?
    // Regular playlist editor (name + song selection): presented for both creating
    // (toEdit == nil) and editing an existing playlist.
    @Published var showingRegularPlaylistEditor = false
    @Published var regularPlaylistToEdit: Playlist?

    enum QueueSource {
        case library
        case folder
        case playlist
    }

    // MARK: - Private/Internal Properties
    internal var libraryManager: LibraryManager?
    internal let playlistFileStore = PlaylistFileStore()

    /// Smart playlists whose tracks are currently being loaded, to collapse concurrent
    /// duplicate loads (e.g. PlaylistDetailView firing onAppear + onChange together).
    /// Mutated only on the main actor.
    internal var loadingSmartPlaylistIDs: Set<UUID> = []

    // MARK: - Dependencies
    internal weak var audioPlayer: PlaybackManager?

    // MARK: - Initialization
    init() {
        // Don't load playlists yet - wait until libraryManager is set
    }

    func setAudioPlayer(_ player: PlaybackManager) {
        self.audioPlayer = player
    }

    func setLibraryManager(_ manager: LibraryManager) {
        self.libraryManager = manager
        Logger.info("Library manager set, loading playlists...")
        loadPlaylists()
    }

    // MARK: - Convenience Methods

    /// Remove track from a specific playlist by ID
    func removeTrackFromPlaylist(track: Track, playlistID: UUID) {
        if let playlist = playlists.first(where: { $0.id == playlistID }) {
            updateTrackInPlaylist(track: track, playlist: playlist, add: false)
        }
    }
    
    func updateSmartPlaylistCounts() {
        // Only auto-updating smart playlists need their count computed from criteria.
        // Frozen playlists already carry the correct count from their persisted snapshot.
        let autoSmart = playlists.filter { $0.type == .smart && ($0.smartCriteria?.autoUpdate ?? true) }
        guard let dbManager = libraryManager?.databaseManager, !autoSmart.isEmpty else { return }

        // One batched read for all counts instead of N separate awaited reads.
        Task {
            let counts = await dbManager.getSmartPlaylistTrackCounts(autoSmart)
            await MainActor.run {
                for (id, count) in counts {
                    if let index = self.playlists.firstIndex(where: { $0.id == id }) {
                        self.playlists[index].trackCount = count
                    }
                }
            }
        }
    }
    
    /// Load all playlists from database
    func loadPlaylists() {
        guard let dbManager = libraryManager?.databaseManager else {
            return
        }
        
        let savedSmartPlaylists = dbManager.loadAllPlaylists()
            .filter { $0.type == .smart }

        playlists = sortPlaylists(smart: savedSmartPlaylists, regular: [])
        
        updateSmartPlaylistCounts()
        reloadFileBackedPlaylists()
    }

    func reloadFileBackedPlaylists() {
        guard let libraryManager else { return }

        let folders = libraryManager.folders
        let dbManager = libraryManager.databaseManager

        Task {
            let result = await playlistFileStore.loadPlaylists(from: folders, databaseManager: dbManager)
            await MainActor.run {
                let smart = self.playlists.filter { $0.type == .smart }
                self.playlists = self.sortPlaylists(smart: smart, regular: result.playlists)

                for (fileURL, missing) in result.missingEntries where !missing.isEmpty {
                    Logger.warning("Playlist \(fileURL.lastPathComponent) has \(missing.count) missing tracks")
                }
            }
        }
    }

    /// Ensure tracks are loaded for a playlist
    func loadPlaylistTracks(for playlistId: UUID) {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }

        if playlist.type == .smart {
            Task { await loadSmartPlaylistTracks(playlist) }
        }
    }
    
    /// Get tracks for a playlist, loading them if needed
    func getPlaylistTracks(_ playlist: Playlist) -> [Track] {
        if playlist.type == .smart {
            return playlist.tracks
        }

        return playlist.tracks
    }
    
    /// Sort playlists: smart playlists first (by dateCreated), then regular playlists (by sortOrder, dateCreated as tiebreaker)
    func sortPlaylists(smart: [Playlist], regular: [Playlist]) -> [Playlist] {
        let sortedSmart = smart.sorted { $0.dateCreated < $1.dateCreated }
        let sortedRegular = regular.sorted {
            $0.sortOrder == $1.sortOrder ? $0.dateCreated < $1.dateCreated : $0.sortOrder < $1.sortOrder
        }
        return sortedSmart + sortedRegular
    }

    /// Reorder user playlists and persist the new order
    func reorderPlaylists(_ reorderedPlaylists: [Playlist]) {
        guard let dbManager = libraryManager?.databaseManager else { return }

        playlists = reorderedPlaylists

        Task {
            do {
                try await dbManager.updatePlaylistsOrder(reorderedPlaylists)
            } catch {
                Logger.error("Failed to reorder playlists: \(error)")
            }
        }
    }
}
