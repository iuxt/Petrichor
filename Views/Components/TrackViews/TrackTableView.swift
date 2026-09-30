import SwiftUI

/// Controls how a row's play action affects the playback queue.
enum QueuePlayBehavior {
    /// Replace the whole queue with the current list and play (default).
    case replace
    /// Append the tapped track to the existing queue and play, leaving the rest
    /// of the queue intact. If the track is already queued, jump to it instead.
    case append
}

struct TrackTableView: View {
    let tracks: [Track]
    let playlistID: UUID?
    let entityID: UUID?
    // Queue source recorded when playing from this table (non-playlist tables); folder detail
    // views pass .folder so row playback keeps folder context, matching the header Play/Shuffle.
    let queueSource: PlaylistManager.QueueSource
    let onPlayTrack: (Track) -> Void
    let contextMenuItems: ([Track], PlaybackManager) -> [ContextMenuItem]
    @Binding var sortOrder: [KeyPathComparator<Track>]
    @Binding var tableRowSize: TableRowSize
    var queuePlayBehavior: QueuePlayBehavior = .replace
    
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager
    
    @State private var selection: Set<Track.ID> = []
    @State private var sortedTracks: [Track] = []
    @State private var sortTask: Task<Void, Never>?
    @State private var artworkRevision = 0
    
    @State private var isCustomSort: Bool = false
    @State private var hasInitializedCustomization = false
    @State private var columnCustomization: TableColumnCustomization<Track> = {
        if let data = UserDefaults.standard.data(forKey: "trackTableColumnCustomizationData"),
           !data.isEmpty,
           let decoded = try? JSONDecoder().decode(TableColumnCustomization<Track>.self, from: data) {
            return decoded
        }
        return TableColumnCustomization<Track>()
    }()
    
    @AppStorage("trackTableColumnCustomizationData")
    private var columnCustomizationData = Data()
    
    private func isCurrentTrack(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    var body: some View {
        tableView
            .onChange(of: columnCustomization) { _, newValue in
                if hasInitializedCustomization {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.saveColumnCustomization(newValue)
                    }
                }
            }
            .onChange(of: sortOrder) { oldValue, newValue in
                if oldValue != newValue {
                    // Table column header click overrides custom sort
                    if isCustomSort {
                        isCustomSort = false
                    }

                    if let playlistID = playlistID {
                        PlaylistSortManager.shared.setSortField(TrackSortField.detect(from: newValue), for: playlistID)
                        PlaylistSortManager.shared.setSortAscending(TrackSortField.isAscending(from: newValue), for: playlistID)
                    }

                    performBackgroundSort(with: newValue)

                    saveSortOrderToUserDefaults(newValue, key: "trackTableSortOrder")

                    NotificationCenter.default.post(
                        name: .trackTableSortChanged,
                        object: nil,
                        userInfo: ["sortOrder": newValue, "fromTable": true]
                    )
                }
            }
            .onChange(of: tracks) {
                if let playlistID = playlistID {
                    isCustomSort = PlaylistSortManager.shared.getSortField(for: playlistID) == .custom
                }
                performBackgroundSort(with: sortOrder)
            }
            .onChange(of: selection) { _, newSelection in
                // Follow the Track Info panel on single selection only;
                // multi-selection and clearing are ignored to avoid ambiguity.
                guard newSelection.count == 1,
                      let trackID = newSelection.first,
                      let track = sortedTracks.first(where: { $0.id == trackID }) else { return }
                NotificationCenter.default.post(
                    name: .trackSelectionChanged,
                    object: nil,
                    userInfo: ["track": track]
                )
            }
            .onAppear {
                initializeSortedTracks()
                hasInitializedCustomization = true
            }
            .onDisappear {
                sortTask?.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
                Task {
                    ArtworkResolver.shared.invalidateMemoryCache()
                    await TrackThumbnailCache.shared.removeAll()
                    artworkRevision += 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .downloadedArtworkDidChange)) { _ in
                artworkRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .playEntityTracks)) { notification in
                handlePlayEntityNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playPlaylistTracks)) { notification in
                handlePlayPlaylistNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .trackTableSortChanged)) { notification in
                handleSortChangedNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .trackTableRowSizeChanged)) { notification in
                handleRowSizeChangedNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .createPlaylistFromSelection)) { _ in
                if !selection.isEmpty {
                    let selectedTracks = sortedTracks.filter { selection.contains($0.id) }
                    if !selectedTracks.isEmpty {
                        playlistManager.showCreatePlaylistModal(with: selectedTracks)
                    }
                }
            }
    }
    
    private var tableView: some View {
        NativeTrackTable(
            tracks: sortedTracks, selection: $selection, sortOrder: $sortOrder,
            customization: $columnCustomization, rowSize: tableRowSize,
            currentTrack: playbackManager.currentTrack, isPlaying: playbackManager.isPlaying,
            artworkRevision: artworkRevision,
            onPlay: handleDoubleTap, onDoubleClick: handleDoubleTap,
            menuItems: { contextMenuItems($0, playbackManager) }
        )
    }

    // MARK: - Helper Methods
    
    private func initializeSortedTracks() {
        sortTask?.cancel()
        // Check for custom sort on playlists (position-based order from DB)
        if let playlistID = playlistID,
           PlaylistSortManager.shared.getSortField(for: playlistID) == .custom {
            isCustomSort = true
            sortedTracks = tracks
            return
        }

        // Follow overridden sort order for entities and playlists
        if entityID != nil || playlistID != nil {
            sortedTracks = tracks.sorted(using: sortOrder)
            return
        }

        if let savedSort = UserDefaults.standard.dictionary(forKey: "trackTableSortOrder"),
           let key = savedSort["key"] as? String,
           let ascending = savedSort["ascending"] as? Bool,
           let field = TrackSortField.from(storageKey: key) {
            let comparator = field.getComparator(ascending: ascending)
            sortOrder = [comparator]
            sortedTracks = tracks.sorted(using: [comparator])
            return
        }
        
        let defaultComparator = KeyPathComparator(\Track.title, order: .forward)
        sortOrder = [defaultComparator]
        sortedTracks = tracks.sorted(using: [defaultComparator])
    }
    
    private func handleDoubleTap(on track: Track) {
        if isCurrentTrack(track) {
            playbackManager.togglePlayPause()
        } else {
            handlePlayTrack(track)
        }
    }
    
    private func handlePlayTrack(_ track: Track) {
        if queuePlayBehavior == .append {
            playlistManager.playTrackByAppendingToQueue(track)
            return
        }

        playlistManager.playTrack(track, fromTracks: sortedTracks)

        if let playlistID = playlistID,
           let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) {
            playlistManager.currentPlaylist = playlist
            playlistManager.currentQueueSource = .playlist
        } else {
            playlistManager.currentQueueSource = queueSource
        }
    }
    
    // MARK: - Sorting Helpers
    
    private func performBackgroundSort(with newSortOrder: [KeyPathComparator<Track>]) {
        sortTask?.cancel()
        sortTask = nil

        // Immediately replace membership (including empty results); never leave
        // rows from the previous query visible while the new sort is running.
        sortedTracks = tracks
        selection.formIntersection(Set(tracks.map(\.id)))
        guard !isCustomSort, !tracks.isEmpty else { return }

        let initialTracks = tracks

        sortTask = Task { @MainActor in
            let sorted = await Task.detached(priority: .userInitiated) {
                initialTracks.sorted(using: newSortOrder)
            }.value
            guard !Task.isCancelled else { return }
            sortedTracks = sorted
            sortTask = nil
        }
    }

    private func saveSortOrderToUserDefaults(_ sortOrder: [KeyPathComparator<Track>], key: String = "trackTableSortOrder") {
        let field = TrackSortField.detect(from: sortOrder)
        let ascending = TrackSortField.isAscending(from: sortOrder)
        let storage: [String: Any] = ["key": field.storageKey, "ascending": ascending]
        UserDefaults.standard.set(storage, forKey: key)
    }
    
    // MARK: - Column Customization Persistence

    private func saveColumnCustomization(_ newValue: TableColumnCustomization<Track>) {
        do {
            let data = try JSONEncoder().encode(newValue)
            columnCustomizationData = data
        } catch {
            Logger.warning("Failed to encode TableColumnCustomization: \(error)")
        }
    }
    
    // MARK: - Notification Handlers
        
    private func handlePlayEntityNotification(_ notification: Notification) {
        guard !sortedTracks.isEmpty,
              let notificationEntityId = notification.userInfo?["entityId"] as? String,
              entityID?.uuidString == notificationEntityId else { return }
        
        let shuffle = notification.userInfo?["shuffle"] as? Bool ?? false
        playlistManager.isShuffleEnabled = shuffle
        
        var tracksForPlayback = sortedTracks
        if shuffle {
            tracksForPlayback.shuffle()
        }
        
        if let firstTrack = tracksForPlayback.first {
            playlistManager.playTrack(firstTrack, fromTracks: tracksForPlayback)
            playlistManager.currentQueueSource = queueSource
        }
    }
    
    private func handlePlayPlaylistNotification(_ notification: Notification) {
        guard let notificationPlaylistID = notification.userInfo?["playlistID"] as? UUID,
              notificationPlaylistID == playlistID,
              !sortedTracks.isEmpty,
              let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) else { return }
        
        let shuffle = notification.userInfo?["shuffle"] as? Bool ?? false
        playlistManager.isShuffleEnabled = shuffle
        
        var tracksForPlayback = sortedTracks
        if shuffle {
            tracksForPlayback.shuffle()
        }
        
        if let firstTrack = tracksForPlayback.first {
            playlistManager.playTrack(firstTrack, fromTracks: tracksForPlayback)
            playlistManager.currentPlaylist = playlist
            playlistManager.currentQueueSource = .playlist
        }
    }

    private func handleSortChangedNotification(_ notification: Notification) {
        // Handle custom sort flag from dropdown
        if let customSort = notification.userInfo?["isCustomSort"] as? Bool {
            isCustomSort = customSort
            if customSort {
                sortedTracks = tracks
                return
            }
        }

        if let newSortOrder = notification.userInfo?["sortOrder"] as? [KeyPathComparator<Track>] {
            sortOrder = newSortOrder

            if let userDefaultsKey = notification.userInfo?["userDefaultsKey"] as? String {
                saveSortOrderToUserDefaults(newSortOrder, key: userDefaultsKey)
            } else {
                saveSortOrderToUserDefaults(newSortOrder)
            }
        }
    }

    private func handleRowSizeChangedNotification(_ notification: Notification) {
        if let newRowSize = notification.userInfo?["rowSize"] as? TableRowSize {
            tableRowSize = newRowSize
        }
    }
    
}

// MARK: - Track Extension for Sorting

extension Track {
    var sortableTrackNumber: Int {
        trackNumber ?? Int.max
    }
    
    var sortableDiscNumber: Int {
        discNumber ?? Int.max
    }
    
    var sortableDateAdded: Date {
        dateAdded ?? Date.distantPast
    }
}
