import SwiftUI

enum RightSidebarContent: Equatable {
    case none
    case queue
    case trackDetail(Track)
    case lyrics
}

private enum MainWindowPanelState: String {
    case none
    case queue
    case lyrics

    init(content: RightSidebarContent) {
        switch content {
        case .queue:
            self = .queue
        case .lyrics:
            self = .lyrics
        case .none, .trackDetail:
            self = .none
        }
    }

    var content: RightSidebarContent {
        switch self {
        case .none:
            return .none
        case .queue:
            return .queue
        case .lyrics:
            return .lyrics
        }
    }
}

private let mainWindowPanelStateKey = "mainWindowPanelState"

private struct ImmersiveToolbarTransition: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: isHidden ? -64 : 0)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .animation(
                .easeInOut(duration: AnimationDuration.immersiveTransition),
                value: isHidden
            )
    }
}

private extension View {
    func immersiveToolbarTransition(isHidden: Bool) -> some View {
        modifier(ImmersiveToolbarTransition(isHidden: isHidden))
    }
}

struct ContentView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject private var localizationSettings: LocalizationSettings
        
    @AppStorage("showFoldersTab")
    private var showFoldersTab = false
    @AppStorage("useArtworkColors")
    private var useArtworkColors = true
    @AppStorage("tintNowPlayingBackground")
    private var tintNowPlayingBackground = true
    @Environment(\.colorScheme)
    private var colorScheme

    @State private var selectedTab: Sections = .home
    @State private var showingSettings = false
    @AppStorage(mainWindowPanelStateKey)
    private var mainWindowPanelState: MainWindowPanelState = .none
    @State private var rightSidebarContent: RightSidebarContent = .none
    @State private var isImmersiveActive = false
    @State private var isImmersiveToolbarContentHidden = false
    // Toolbar state captured before immersive hides it, so closing restores it.
    @State private var immersiveToolbarWasVisible = true
    @State private var pendingLibraryFilter: LibraryFilterRequest?
    @State private var windowDelegate = WindowDelegate()
    @State private var shouldFocusSearch = false

    // Sidebar selection state (owned here, passed as bindings to sidebars + content views)
    @State private var selectedHomeSidebarItem: HomeSidebarItem?
    @State private var selectedPlaylist: Playlist?
    @State private var selectedFolderNode: FolderNode?
    @AppStorage("librarySelectedFilterType")
    private var libraryFilterType: LibraryFilterType = .artists
    @State private var libraryFilterItem: LibraryFilterItem?
    @State private var libraryPendingSearchText: String?
    @State private var libraryFilteredItems: [LibraryFilterItem] = []
    @State private var libraryCachedTracks: [Track] = []
    @State private var librarySelectedSidebarItem: LibrarySidebarItem?
    
    @ObservedObject private var notificationManager = NotificationManager.shared

    init() {
        let raw = UserDefaults.standard.string(forKey: mainWindowPanelStateKey)
        let restoredPanel = MainWindowPanelState(rawValue: raw ?? "") ?? .none
        _rightSidebarContent = State(initialValue: restoredPanel.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // Main Content Area with Queue
            mainContentArea

            playerControls
                .animation(.easeInOut(duration: 0.3), value: libraryManager.folders.isEmpty)
        }
        .environment(\.locale, localizationSettings.locale)
        .id(localizationSettings.appLanguage.id)
        .onKeyPress(.space) {
            if isCurrentlyEditingText() {
                return .ignored
            }
            
            if playbackManager.currentTrack != nil {
                DispatchQueue.main.async {
                    playbackManager.togglePlayPause()
                }
                return .handled
            }
            
            return .ignored
        }
        .frame(minWidth: 1000, minHeight: 600)
        .overlay {
            if isImmersiveActive {
                ImmersiveView(
                    isPresented: $isImmersiveActive,
                    artwork: NowPlayingArtwork.image(for: playbackManager.currentTrack),
                    gradient: NowPlayingArtwork.gradient(
                        for: playbackManager.currentTrack,
                        isDark: colorScheme == .dark,
                        enabled: useArtworkColors && tintNowPlayingBackground
                    ),
                    trackID: playbackManager.currentTrack?.id,
                    isDarkMode: colorScheme == .dark
                )
                .transition(.move(edge: .bottom))
            }
        }
        .onChange(of: isImmersiveActive) { _, active in
            if !active {
                restoreToolbarForImmersiveClose()
            }
        }
        .onAppear(perform: handleOnAppear)
        .contentViewNotificationHandlers(
            shouldFocusSearch: $shouldFocusSearch,
            showingSettings: $showingSettings,
            selectedTab: $selectedTab,
            pendingLibraryFilter: $pendingLibraryFilter,
            showTrackDetail: showTrackDetail
        )
        .onChange(of: playbackManager.currentTrack?.id) { oldId, _ in
            if case .trackDetail(let currentDetailTrack) = rightSidebarContent,
               currentDetailTrack.id == oldId,
               let newTrack = playbackManager.currentTrack {
                rightSidebarContent = .trackDetail(newTrack)
            }
        }
        .onChange(of: rightSidebarContent) { _, newValue in
            mainWindowPanelState = MainWindowPanelState(content: newValue)
        }
        .onChange(of: libraryManager.globalSearchText) { oldValue, newValue in
            handleGlobalSearchChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: showFoldersTab) { _, newValue in
            if !newValue && selectedTab == .folders {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedTab = .home
                }
            }
        }
        .background(WindowAccessor(windowDelegate: windowDelegate))
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                modernToolbarContent
            } else {
                toolbarContent
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(libraryManager)
        }
        .sheet(isPresented: $playlistManager.showingCreatePlaylistModal) {
            CreatePlaylistSheet(
                isPresented: $playlistManager.showingCreatePlaylistModal,
                playlistName: $playlistManager.newPlaylistName,
                tracksToAdd: playlistManager.tracksToAddToNewPlaylist
            ) {
                playlistManager.createPlaylistFromModal()
            }
            .environmentObject(playlistManager)
        }
        .sheet(isPresented: $playlistManager.showingSmartPlaylistEditor) {
            SmartPlaylistEditorSheet(
                isPresented: $playlistManager.showingSmartPlaylistEditor,
                editingPlaylist: playlistManager.smartPlaylistToEdit
            )
            .environmentObject(playlistManager)
        }
        .sheet(isPresented: $playlistManager.showingRegularPlaylistEditor) {
            RegularPlaylistEditorSheet(
                isPresented: $playlistManager.showingRegularPlaylistEditor,
                editingPlaylist: playlistManager.regularPlaylistToEdit
            )
            .environmentObject(libraryManager)
            .environmentObject(playlistManager)
        }
        .sheet(item: $libraryManager.pendingMergeRequest) { request in
            MergeEntitySheet(request: request)
                .environmentObject(libraryManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleImmersivePlayer)) { _ in
            guard playbackManager.currentTrack != nil || isImmersiveActive else { return }
            if isImmersiveActive {
                withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
                    isImmersiveActive = false
                }
            } else {
                openImmersive()
            }
        }
    }

    /// Opens immersive mode, animating toolbar content out before the native
    /// toolbar is collapsed so the main content does not visibly reflow.
    private func openImmersive() {
        immersiveToolbarWasVisible = WindowManager.shared.mainWindow?.toolbar?.isVisible ?? true
        withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
            isImmersiveToolbarContentHidden = true
            isImmersiveActive = true
        } completion: {
            // Guard against a quick re-close before the open animation completes.
            if isImmersiveActive {
                WindowManager.shared.mainWindow?.toolbar?.isVisible = false
            }
        }
    }

    /// Restores the native toolbar first, then gives its SwiftUI content one frame
    /// in the hidden position before animating it back down.
    private func restoreToolbarForImmersiveClose() {
       WindowManager.shared.mainWindow?.toolbar?.isVisible = immersiveToolbarWasVisible
       DispatchQueue.main.async {
           // Skip if immersive was reopened before this deferred restore runs;
           // otherwise we'd flip content back to visible mid-open.
           guard !isImmersiveActive else { return }
           withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
               isImmersiveToolbarContentHidden = false
           }
       }
    }

    // MARK: - View Components

    @ViewBuilder private var mainContentArea: some View {
        if !libraryManager.shouldShowMainUI {
            NoMusicEmptyStateView(context: .mainWindow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PersistentSplitView(
                left: {
                    leftSidebar
                },
                center: {
                    sectionContent
                },
                right: {
                    sidePanel
                }
            )
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var leftSidebar: some View {
        ZStack {
            HomeSidebarView(selectedItem: $selectedHomeSidebarItem)
                .opacity(selectedTab == .home ? 1 : 0)
                .allowsHitTesting(selectedTab == .home)

            if selectedTab == .library {
                LibrarySidebarView(
                    selectedFilterType: $libraryFilterType,
                    selectedFilterItem: $libraryFilterItem,
                    pendingSearchText: $libraryPendingSearchText,
                    filteredItems: $libraryFilteredItems,
                    selectedSidebarItem: $librarySelectedSidebarItem
                )
            }

            if selectedTab == .playlists {
                PlaylistSidebarView(selectedPlaylist: $selectedPlaylist)
            }

            if selectedTab == .folders {
                FoldersSidebarView(selectedNode: $selectedFolderNode)
            }
        }
    }

    private var sectionContent: some View {
        ZStack {
            HomeView(selectedSidebarItem: $selectedHomeSidebarItem, isShowingEntities: .constant(false))
                .opacity(selectedTab == .home ? 1 : 0)
                .allowsHitTesting(selectedTab == .home)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedTab == .library {
                LibraryView(
                    selectedFilterType: $libraryFilterType,
                    selectedFilterItem: $libraryFilterItem,
                    pendingSearchText: $libraryPendingSearchText,
                    cachedFilteredTracks: $libraryCachedTracks,
                    pendingFilter: $pendingLibraryFilter
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if selectedTab == .playlists {
                PlaylistsView(selectedPlaylist: $selectedPlaylist)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if selectedTab == .folders && showFoldersTab {
                FoldersView(selectedFolderNode: $selectedFolderNode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var sidePanel: some View {
        switch rightSidebarContent {
        case .queue:
            PlayQueueView(showingQueue: Binding(
                get: { rightSidebarContent == .queue },
                set: { if !$0 { rightSidebarContent = .none } }
            ))
            .background(.ultraThinMaterial)
        case .trackDetail(let track):
            TrackDetailView(track: track) {
                rightSidebarContent = .none
            }
        case .lyrics:
            TrackLyricsView {
                rightSidebarContent = .none
            }
            .background(.ultraThinMaterial)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var playerControls: some View {
        if libraryManager.shouldShowMainUI {
            Divider()

            PlayerView(
                rightSidebarContent: $rightSidebarContent
            )
                .frame(height: 110)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TabbedButtons(
                items: Sections.allCases.filter { $0 != .folders || showFoldersTab },
                selection: $selectedTab,
                animation: .transform,
                isDisabled: libraryManager.folders.isEmpty
            )
            .id(localizationSettings.appLanguage.rawValue)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
        }

        // Do not remove this spacer, it allows
        // for pushing toolbar items below to the
        // right-edge of window frame on macOS 14.x
        ToolbarItem { Spacer() }

        ToolbarItem(placement: .confirmationAction) {
            HStack(spacing: 8) {
                NotificationTray()
                    .frame(width: 24, height: 24)

                SearchInputField(
                    text: $libraryManager.globalSearchText,
                    placeholder: "Search",
                    fontSize: 12,
                    shouldFocus: shouldFocusSearch
                )
                .frame(width: 280)
                .disabled(!libraryManager.shouldShowMainUI)
            }
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
        }
    }

    @available(macOS 26.0, *)
    @ToolbarContentBuilder private var modernToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            TabbedButtons(
                items: Sections.allCases.filter { $0 != .folders || showFoldersTab },
                selection: $selectedTab,
                style: .modern,
                animation: .transform,
                isDisabled: libraryManager.folders.isEmpty
            )
            .id(localizationSettings.appLanguage.rawValue)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
        }

        ToolbarItem(placement: .confirmationAction) {
            NotificationTray()
                .frame(width: 34, height: 30)
                .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
        }
        .adaptiveSharedBackgroundHidden()

        ToolbarItem(placement: .confirmationAction) {
            SearchInputField(
                text: $libraryManager.globalSearchText,
                placeholder: "Search",
                fontSize: 12,
                shouldFocus: shouldFocusSearch
            )
            .frame(width: 280)
            .disabled(!libraryManager.shouldShowMainUI)
            .immersiveToolbarTransition(isHidden: isImmersiveToolbarContentHidden)
        }
    }
    
    // MARK: - Event Handlers

    private func handleOnAppear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func handleGlobalSearchChange(oldValue: String, newValue: String) {
        if oldValue.isEmpty && !newValue.isEmpty {
            selectAllLibrarySearchResults()
        }

        if !newValue.isEmpty && selectedTab != .library {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedTab = .library
            }
        }
    }

    private func selectAllLibrarySearchResults() {
        let totalCount = libraryManager.searchResults.count
        libraryFilterItem = LibraryFilterItem.allItem(for: libraryFilterType, totalCount: totalCount)
        librarySelectedSidebarItem = LibrarySidebarItem(allItemFor: libraryFilterType, count: totalCount)
        libraryCachedTracks = libraryManager.searchResults
    }

    // MARK: - Helper Methods

    private func showTrackDetail(for track: Track) {
        rightSidebarContent = .trackDetail(track)
    }

    private func isCurrentlyEditingText() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        
        if firstResponder is NSText || firstResponder is NSTextView {
            return true
        }
        
        if let textField = firstResponder as? NSTextField, textField.isEditable {
            return true
        }
        
        return false
    }
}

extension View {
    func contentViewNotificationHandlers(
        shouldFocusSearch: Binding<Bool>,
        showingSettings: Binding<Bool>,
        selectedTab: Binding<Sections>,
        pendingLibraryFilter: Binding<LibraryFilterRequest?>,
        showTrackDetail: @escaping (Track) -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
                shouldFocusSearch.wrappedValue.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToLibraryFilter)) { notification in
                if let filterType = notification.userInfo?["filterType"] as? LibraryFilterType,
                   let filterValue = notification.userInfo?["filterValue"] as? String {
                    withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
                        selectedTab.wrappedValue = .library
                        pendingLibraryFilter.wrappedValue = LibraryFilterRequest(filterType: filterType, value: filterValue)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowTrackInfo"))) { notification in
                if let track = notification.userInfo?["track"] as? Track {
                    showTrackDetail(track)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
                showingSettings.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsAboutTab"))) { _ in
                showingSettings.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SettingsSelectTab"),
                        object: SettingsView.SettingsTab.about
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPlaylists)) { notification in
                if let playlistID = notification.userInfo?["playlistID"] as? UUID {
                    // Only animate tab switch if not already on playlists
                    if selectedTab.wrappedValue != .playlists {
                        withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
                            selectedTab.wrappedValue = .playlists
                        }
                    }
                    // Select the playlist in the sidebar
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(
                            name: .selectPlaylist,
                            object: nil,
                            userInfo: ["playlistID": playlistID]
                        )
                    }
                }
            }
    }
}

// MARK: - Create Playlist Sheet

struct CreatePlaylistSheet: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var isPresented: Bool
    @Binding var playlistName: String
    let tracksToAdd: [Track]
    let onCreate: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Playlist")
                .font(.headline)

            TextField("Playlist Name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit {
                    if !playlistName.isEmpty {
                        onCreate()
                    }
                }

            if !tracksToAdd.isEmpty {
                Text("Will add: \(tracksToAdd.count) tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    playlistName = ""
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    onCreate()
                }
                .keyboardShortcut(.return)
                .disabled(playlistName.isEmpty)
            }
        }
        .padding(30)
        .frame(width: 350)
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let windowDelegate: WindowDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = windowDelegate
                window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.mainWindow)
                window.setFrameAutosaveName(WindowIdentifier.mainWindow)
                WindowManager.shared.mainWindow = window
                window.title = ""
                window.isExcludedFromWindowsMenu = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Manager

class WindowManager {
    static let shared = WindowManager()
    weak var mainWindow: NSWindow?

    private init() {}
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playbackManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            NotificationManager.shared.isActivityInProgress = true
            coordinator.libraryManager.folders = [Folder(url: URL(fileURLWithPath: "/Music"))]
            return coordinator.libraryManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playlistManager
        }())
}
