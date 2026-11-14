import SwiftUI

// MARK: - Editor Tab

private enum EditorTab: TabbedItem {
    case playlist
    case add

    var title: String {
        switch self {
        case .playlist: return String(appLocalized: "Playlist")
        case .add: return String(appLocalized: "Add Songs")
        }
    }

    // Titles only; the shared component hides icons when `showIcon` is false.
    var icon: String { "" }
}

// MARK: - Regular Playlist Editor Sheet

/// Unified editor for regular playlists, presented for both creating a new playlist
/// (`editingPlaylist == nil`) and editing an existing one.
///
/// The contents are split across two tabs so adding and removing never share a control:
/// - "Playlist" lists the staged contents (current tracks plus anything added this
///   session); each row removes, and a "Remove All" clears the lot.
/// - "Add Songs" is a library search; each result adds, and "Add All" adds every match.
///   Songs already in the playlist still appear in the matches but are dimmed and have no
///   add button, so the search stays a complete picture of the library.
///
/// The staged list is always the exact set that will be saved.
struct RegularPlaylistEditorSheet: View {
    @Binding var isPresented: Bool
    private let editingPlaylist: Playlist?
    private let originalName: String

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @State private var name: String
    @State private var selectedTab: EditorTab

    // Staged playlist contents: the source of truth for what the playlist will contain on
    // save. Seeded from the existing playlist in edit mode (loaded on appear), grows as the
    // user adds from the search tab and shrinks as they remove.
    @State private var playlistTracks: [Track] = []

    // Count staged changes by occurrence, including repeated entries in imported M3Us.
    private let originalRowIDs: Set<UUID>

    // Set once the user drags to reorder, so save only rewrites positions when needed.
    @State private var didReorder = false

    // Add-songs search state.
    @State private var searchText = ""
    @State private var searchResults: [Track] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?

    // Playlist-tab filter state (FTS5-backed). `filterMatchIDs` is nil when no filter is
    // active; otherwise it holds the database IDs of the library tracks matching the query.
    @State private var playlistFilter = ""
    @State private var filterMatchIDs: Set<Int64>?
    @State private var completedFilterQuery: String?
    @State private var filterTask: Task<Void, Never>?

    init(isPresented: Binding<Bool>, editingPlaylist: Playlist?) {
        self._isPresented = isPresented
        self.editingPlaylist = editingPlaylist
        let tracks = editingPlaylist?.tracks ?? []
        _playlistTracks = State(initialValue: tracks)
        originalRowIDs = Set(tracks.map(\.id))
        self.originalName = editingPlaylist?.name ?? ""
        _name = State(initialValue: editingPlaylist?.name ?? "")
        // Start on the relevant tab: an existing playlist opens to its contents, a new one
        // opens straight to search since there's nothing to show yet.
        _selectedTab = State(initialValue: editingPlaylist == nil ? .add : .playlist)
    }

    private var isEditing: Bool { editingPlaylist != nil }

    // Shared height so the search box and the bulk-action buttons line up.
    private static let controlHeight: CGFloat = 28

    // Title-only, full-width tabs using the shared component.
    private static let tabStyle = TabbedButtonStyle(
        showIcon: false,
        showTitle: true,
        iconSize: 12,
        textSize: 12,
        iconTextSpacing: 0,
        buttonWidth: nil,
        verticalPadding: 5,
        contentShapeRadius: 6,
        backgroundViewRadius: 6,
        expandButtons: true,
        horizontalContentPadding: 0
    )

    var body: some View {
        VStack(spacing: 0) {
            PlaylistEditorHeader(title: headerTitle) { isPresented = false }

            Divider()

            nameSection

            tabPicker

            Divider()

            switch selectedTab {
            case .playlist:
                playlistTab
            case .add:
                addTab
            }

            Divider()

            PlaylistEditorFooter(
                summary: changeSummary,
                saveTitle: saveButtonTitle,
                canSave: canSave,
                onCancel: { isPresented = false },
                onSave: { save() }
            )
        }
        .frame(width: 640, height: 700)
        .onDisappear {
            searchTask?.cancel()
            filterTask?.cancel()
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        isEditing ? String(appLocalized: "Edit Playlist") : String(appLocalized: "New Playlist")
    }

    private var saveButtonTitle: String {
        isEditing ? String(appLocalized: "Save") : String(appLocalized: "Create")
    }

    private var nameSection: some View {
        PlaylistNameField(name: $name)
    }

    private var tabPicker: some View {
        TabbedButtons(
            items: [.playlist, .add],
            selection: $selectedTab,
            style: Self.tabStyle,
            animation: .transform
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Playlist Tab

    private var playlistTab: some View {
        VStack(spacing: 0) {
            if !playlistTracks.isEmpty {
                HStack(spacing: 8) {
                    searchBox(text: $playlistFilter, placeholder: "Filter songs...", onChange: filterPlaylist)

                    Button("Remove", role: .destructive) {
                        removeDisplayed()
                    }
                    .buttonStyle(.bordered)
                    .frame(height: Self.controlHeight)
                    .disabled(displayedPlaylistTracks.isEmpty)
                    .help(removeHelp)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }

            if playlistTracks.isEmpty {
                emptyPlaylistHint
            } else if LibrarySearch.isSearchableQuery(filterQuery), completedFilterQuery != filterQuery {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedPlaylistTracks.isEmpty {
                noFilterMatchesView
            } else {
                // Drag rows to reorder (disabled while filtering, since the visible list is a
                // subset). The order is persisted on save.
                List {
                    ForEach(displayedPlaylistTracks, id: \.id) { track in
                        EditorTrackRow(
                            track: track,
                            accessory: .remove { removeTrack(track) },
                            isReorderable: !isFiltering
                        )
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    .onMove(perform: isFiltering ? nil : moveTrack)
                }
                .listStyle(.plain)
            }

            // Doubles as the drag affordance and explains how the manual order surfaces.
            // Hidden while filtering, where reordering is disabled.
            if playlistTracks.count > 1 && !isFiltering {
                Divider()
                reorderHint
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var reorderHint: some View {
        HStack(spacing: 6) {
            Image(systemName: Icons.infoCircle)
                .font(.system(size: 12))
            Text("Drag to reorder. This order is shown when the playlist is sorted by \"Custom\".")
                .font(.subheadline)
            Spacer()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var noFilterMatchesView: some View {
        VStack(spacing: 8) {
            Image(systemName: Icons.magnifyingGlass)
                .font(.system(size: 32))
                .foregroundColor(.gray)
            Text("No songs match your filter")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyPlaylistHint: some View {
        VStack(spacing: 8) {
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 36))
                .foregroundColor(.gray)
            Text("No songs yet")
                .font(.subheadline)
            Button("Add Songs") {
                selectedTab = .add
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Add Tab

    private var addTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                searchField

                if addableCount > 0 {
                    Button("Add All") {
                        addAllResults()
                    }
                    .buttonStyle(.bordered)
                    .frame(height: Self.controlHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if isSearching {
                loadingView
            } else if !hasSearched {
                addPromptView
            } else if searchResults.isEmpty {
                noResultsView
            } else {
                List(searchResults, id: \.id) { track in
                    let staged = track.trackId.map { stagedTrackIDs.contains($0) } ?? false
                    EditorTrackRow(
                        track: track,
                        accessory: staged ? .inPlaylist : .add { addTrack(track) }
                    )
                    .listRowSeparator(.visible)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var searchField: some View {
        searchBox(text: $searchText, placeholder: "Search your library...", onChange: performSearch)
    }

    private func searchBox(text: Binding<String>, placeholder: LocalizedStringKey, onChange: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: Icons.magnifyingGlass)
                .foregroundColor(.secondary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .onSubmit { onChange() }
                .onChange(of: text.wrappedValue) { onChange() }

            if !text.wrappedValue.isEmpty {
                Button(action: {
                    text.wrappedValue = ""
                    onChange()
                }, label: {
                    Image(systemName: Icons.xmarkCircleFill)
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }


    // MARK: - Search State Views

    private var addPromptView: some View {
        VStack(spacing: 8) {
            Image(systemName: Icons.magnifyingGlass)
                .font(.system(size: 32))
                .foregroundColor(.gray)
            Text("Search your library to add songs")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Searching...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: Icons.magnifyingGlass)
                .font(.system(size: 32))
                .foregroundColor(.gray)

            if !LibrarySearch.isSearchableQuery(searchText) {
                Text("Type at least 2 characters to search")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("No songs found")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Derived State, Actions & Search

extension RegularPlaylistEditorSheet {
    private var stagedTrackIDs: Set<Int64> {
        Set(playlistTracks.compactMap { $0.trackId })
    }

    private var filterQuery: String { playlistFilter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFiltering: Bool { !filterQuery.isEmpty }

    /// Staged tracks shown in the Playlist tab: all of them, or just the filter matches.
    private var displayedPlaylistTracks: [Track] {
        guard isFiltering else { return playlistTracks }
        guard completedFilterQuery == filterQuery, let ids = filterMatchIDs else { return [] }
        return playlistTracks.filter { track in track.trackId.map { ids.contains($0) } ?? false }
    }

    private var removeHelp: String {
        isFiltering ? String(appLocalized: "Remove matching songs") : String(appLocalized: "Remove all songs")
    }

    /// Tracks staged that weren't in the original playlist.
    private var addedCount: Int {
        playlistTracks.filter { !originalRowIDs.contains($0.id) }.count
    }

    /// Original tracks no longer staged.
    private var removedCount: Int {
        originalRowIDs.subtracting(playlistTracks.map(\.id)).count
    }

    /// Search matches not already in the playlist (i.e. what "Add All" would add).
    private var addableCount: Int {
        let staged = stagedTrackIDs
        return searchResults.filter { track in
            track.trackId.map { !staged.contains($0) } ?? true
        }.count
    }

    private var hasChanges: Bool {
        addedCount > 0 || removedCount > 0
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isEditing {
            return hasChanges || didReorder || name != originalName
        }
        return true
    }

    /// Concise pending-change summary shown bottom-left next to Cancel/Save; nil when
    /// nothing has changed yet.
    private var changeSummary: String? {
        let added = addedCount
        let removed = removedCount
        if added > 0 && removed > 0 {
            return String(appLocalized: "Add \(HelperUtils.songCount(added)), remove \(HelperUtils.songCount(removed))")
        } else if added > 0 {
            return String(appLocalized: "Add \(HelperUtils.songCount(added))")
        } else if removed > 0 {
            return String(appLocalized: "Remove \(HelperUtils.songCount(removed))")
        }
        return nil
    }

    // MARK: - Add / Remove

    private func addTrack(_ track: Track) {
        guard let trackId = track.trackId, !stagedTrackIDs.contains(trackId) else { return }
        var staged = track
        staged.dateAdded = Date()
        playlistTracks.append(staged)
    }

    private func addAllResults() {
        let staged = stagedTrackIDs
        let now = Date()
        let toAdd = searchResults
            .filter { track in track.trackId.map { !staged.contains($0) } ?? false }
            .map { track -> Track in
                var copy = track
                copy.dateAdded = now
                return copy
            }
        playlistTracks.append(contentsOf: toAdd)
    }

    private func removeTrack(_ track: Track) {
        playlistTracks.removeAll { $0.id == track.id }
    }

    /// Removes the currently-visible tracks: everything when unfiltered, or just the matches
    /// when a filter is active (bulk remove by search criteria).
    private func removeDisplayed() {
        if isFiltering {
            let ids = Set(displayedPlaylistTracks.compactMap { $0.trackId })
            playlistTracks.removeAll { track in track.trackId.map { ids.contains($0) } ?? false }
        } else {
            playlistTracks.removeAll()
        }
    }

    private func moveTrack(from source: IndexSet, to destination: Int) {
        playlistTracks.move(fromOffsets: source, toOffset: destination)
        didReorder = true
    }

    // MARK: - Playlist Filter

    private func filterPlaylist() {
        filterTask?.cancel()
        let query = filterQuery
        completedFilterQuery = nil
        filterMatchIDs = nil
        guard LibrarySearch.isSearchableQuery(query) else { return }
        let database = libraryManager.databaseManager
        filterTask = Task {
            try? await Task.sleep(nanoseconds: TimeConstants.searchDebounceDuration)
            guard !Task.isCancelled else { return }

            // Same FTS5 path as the add search and library search; intersect with the staged
            // tracks at display time.
            let ids = await Task.detached(priority: .userInitiated) {
                Set(database.searchTracksUsingFTS(query).compactMap(\.trackId))
            }.value

            await MainActor.run {
                guard !Task.isCancelled, filterQuery == query else { return }
                completedFilterQuery = query
                filterMatchIDs = ids
            }
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if let editingPlaylist {
            if hasChanges || didReorder {
                guard playlistManager.saveEditedTracks(playlistTracks, original: editingPlaylist) else { return }
                if didReorder {
                    PlaylistSortManager.shared.setSortField(.custom, for: editingPlaylist.id)
                    NotificationCenter.default.post(
                        name: .trackTableSortChanged, object: nil,
                        userInfo: ["isCustomSort": true, "sortPlaylistID": editingPlaylist.id.uuidString]
                    )
                }
            }
            if trimmedName != originalName,
               let current = playlistManager.playlists.first(where: { $0.id == editingPlaylist.id }) {
                playlistManager.renamePlaylist(current, newName: trimmedName)
            }
        } else {
            playlistManager.createRegularPlaylist(name: trimmedName, tracks: playlistTracks)
        }
        isPresented = false
    }

    // MARK: - Search

    private func performSearch() {
        searchTask?.cancel()

        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            searchResults = []
            isSearching = false
            hasSearched = false
            return
        }

        guard LibrarySearch.isSearchableQuery(trimmedQuery) else {
            searchResults = []
            hasSearched = true
            isSearching = false
            return
        }

        searchResults = []
        isSearching = true
        hasSearched = true

        let database = libraryManager.databaseManager
        searchTask = Task {
            try? await Task.sleep(nanoseconds: TimeConstants.searchDebounceDuration)
            guard !Task.isCancelled else { return }

            // Keep every match; tracks already in the playlist are shown dimmed (not hidden)
            // so the results stay a full picture of the library.
            let results = await Task.detached(priority: .userInitiated) {
                database.searchTracksUsingFTS(trimmedQuery)
            }.value

            await MainActor.run {
                guard !Task.isCancelled else { return }
                searchResults = results
                isSearching = false
            }
        }
    }
}

// MARK: - Editor Track Row

private struct EditorTrackRow: View {
    enum Accessory {
        case add(() -> Void)
        case remove(() -> Void)
        case inPlaylist
    }

    let track: Track
    let accessory: Accessory
    var isReorderable: Bool = false

    /// Tracks already in the playlist are dimmed in the add results.
    private var isDimmed: Bool {
        if case .inPlaylist = accessory { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            if isReorderable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text("\(track.displayArtist) • \(track.displayAlbum)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .opacity(isDimmed ? 0.4 : 1)

            Spacer()

            Text(HelperUtils.formattedShortDuration(track.duration))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .opacity(isDimmed ? 0.4 : 1)

            accessoryView
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var accessoryView: some View {
        switch accessory {
        case .add(let action):
            Button(action: action) {
                Image(systemName: Icons.plusCircleFill)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add to playlist")

        case .remove(let action):
            Button(action: action) {
                Image(systemName: Icons.minusCircleFill)
                    .font(.system(size: 16))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove from playlist")

        case .inPlaylist:
            Text("In playlist")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview("Create") {
    RegularPlaylistEditorSheet(isPresented: .constant(true), editingPlaylist: nil)
        .environmentObject(LibraryManager())
        .environmentObject(PlaylistManager())
}

#Preview("Edit") {
    RegularPlaylistEditorSheet(
        isPresented: .constant(true),
        editingPlaylist: Playlist(name: "My Playlist", tracks: [])
    )
    .environmentObject(LibraryManager())
    .environmentObject(PlaylistManager())
}
