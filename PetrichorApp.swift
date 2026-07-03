import SwiftUI

@main
struct PetrichorApp: App {
    @StateObject private var appCoordinator: AppCoordinator
    @StateObject private var localizationSettings: LocalizationSettings
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    init() {
        AppDelegate.registerUserDefaultsDefaults()
        _appCoordinator = StateObject(wrappedValue: AppCoordinator())
        _localizationSettings = StateObject(wrappedValue: LocalizationSettings())
    }
    
    @AppStorage("showFoldersTab")
    private var showFoldersTab = false
    
    @AppStorage("closeToMenubar")
    private var closeToMenubar = true

    @AppStorage("miniPlayerAlwaysOnTop")
    private var miniPlayerAlwaysOnTop = false

    @AppStorage("desktopLyricsEnabled")
    private var desktopLyricsEnabled = false

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false

    @State private var menuUpdateTrigger = UUID()
    @Environment(\.openWindow)
    private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator.playbackManager)
                .environmentObject(appCoordinator.playbackManager.playbackProgressState)
                .environmentObject(appCoordinator.libraryManager)
                .environmentObject(appCoordinator.playlistManager)
                .environmentObject(localizationSettings)
                .environment(\.locale, localizationSettings.locale)
                .onReceive(appCoordinator.playlistManager.$repeatMode) { _ in
                    menuUpdateTrigger = UUID()
                }
                .onReceive(appCoordinator.playbackManager.$currentTrack) { _ in
                    menuUpdateTrigger = UUID()
                }
                .onReceive(appCoordinator.playlistManager.$isShuffleEnabled) { _ in
                    menuUpdateTrigger = UUID()
                }
                .onReceive(localizationSettings.$appLanguage) { _ in
                    menuUpdateTrigger = UUID()
                    appCoordinator.menuBarManager.refreshMenu()
                }
                .onAppear {
                    if desktopLyricsEnabled {
                        DesktopLyricsWindowManager.shared.show()
                    }
                }
                .onChange(of: desktopLyricsEnabled) { _, enabled in
                    if enabled {
                        DesktopLyricsWindowManager.shared.show()
                    } else {
                        DesktopLyricsWindowManager.shared.close()
                    }
                }
                .onChange(of: desktopLyricsClickThrough) {
                    DesktopLyricsWindowManager.shared.applyCurrentSettings()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["main"])
        
        equalizerWindow

        .commands {
            // App Menu Commands
            appMenuCommands()
            
            // File Menu Commands
            fileMenuCommands()
            
            // Playback Menu
            playbackMenuCommands()
            
            // View Menu Commands
            viewMenuCommands()
            
            // Window Menu Commands
            windowMenuCommands()
            
            // Help Menu Commands
            helpMenuCommands()
        }
    }
    
    private var equalizerWindow: some Scene {
        WindowGroup("Equalizer", id: "equalizer") {
            EqualizerView()
                .environmentObject(appCoordinator.playbackManager)
                .environmentObject(localizationSettings)
                .environment(\.locale, localizationSettings.locale)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 500, height: 300)
        .windowResizability(.contentSize)
    }
}

extension PetrichorApp {
    // MARK: - App Menu Commands
    
    @CommandsBuilder
    private func appMenuCommands() -> some Commands {
        CommandGroup(replacing: .appSettings) {}
        
        CommandGroup(replacing: .appInfo) {
            aboutMenuItem()
        }
        
        CommandGroup(after: .appInfo) {
            settingsMenuItem()
        }
        
    }
    
    private func aboutMenuItem() -> some View {
        Button {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenSettingsAboutTab"),
                object: nil
            )
        } label: {
            if #available(macOS 26.0, *) {
                Label("About Petrichor", systemImage: Icons.infoCircle)
            } else {
                Text("About Petrichor")
            }
        }
    }
    
    private func settingsMenuItem() -> some View {
        Button {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenSettings"),
                object: nil
            )
        } label: {
            if #available(macOS 26.0, *) {
                Label("Settings", systemImage: Icons.settings)
            } else {
                Text("Settings")
            }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
    
    // MARK: - File Menu Commands

    @CommandsBuilder
    private func fileMenuCommands() -> some Commands {
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(replacing: .newItem) {
            // New submenu
            Menu {
                newPlaylistMenuItem()
                newPlaylistFromSelectionMenuItem()
            } label: {
                if #available(macOS 26.0, *) {
                    Label("New", systemImage: "plus.square")
                } else {
                    Text("New")
                }
            }
            
            Divider()
            
            // Library submenu
            Menu {
                addFolderMenuItem()
                refreshLibraryMenuItem()
            } label: {
                if #available(macOS 26.0, *) {
                    Label("Library", image: "custom.music.note.rectangle.stack")
                } else {
                    Text("Library")
                }
            }
            
            Divider()
            
            closeWindowMenuItem()
        }
    }
    
    private func closeWindowMenuItem() -> some View {
        Button {
            closeWindow()
        } label: {
            if #available(macOS 26.0, *) {
                Label("Close", systemImage: "xmark")
            } else {
                Text("Close")
            }
        }
        .keyboardShortcut("w", modifiers: .command)
    }
    
    private func closeWindow() {
        guard let window = NSApp.keyWindow else { return }
        
        let isMainWindow = window.identifier?.rawValue == WindowIdentifier.mainWindow
        
        if closeToMenubar && isMainWindow {
            appCoordinator.savePlaybackState()
            window.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            window.close()
        }
    }

    // MARK: - New Menu Items

    private func newPlaylistMenuItem() -> some View {
        Button {
            appCoordinator.playlistManager.showCreatePlaylistModal()
        } label: {
            if #available(macOS 26.0, *) {
                Label("Playlist", systemImage: Icons.musicNoteList)
            } else {
                Text("Playlist")
            }
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private func newPlaylistFromSelectionMenuItem() -> some View {
        Button {
            NotificationCenter.default.post(
                name: .createPlaylistFromSelection,
                object: nil
            )
        } label: {
            if #available(macOS 26.0, *) {
                Label("Playlist from Selection", systemImage: Icons.musicNoteList)
            } else {
                Text("Playlist from Selection")
            }
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    // MARK: - Library Menu Items

    private func addFolderMenuItem() -> some View {
        Button {
            appCoordinator.libraryManager.addFolder()
        } label: {
            if #available(macOS 26.0, *) {
                Label("Add Folder(s) to Library", systemImage: Icons.folderBadgePlus)
            } else {
                Text("Add Folder(s) to Library")
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }

    private func refreshLibraryMenuItem() -> some View {
        Button {
            appCoordinator.libraryManager.refreshLibrary()
        } label: {
            if #available(macOS 26.0, *) {
                Label("Refresh Library Folders", systemImage: Icons.arrowClockwise)
            } else {
                Text("Refresh Library Folders")
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    // MARK: - Playback Menu Commands
    
    @CommandsBuilder
    private func playbackMenuCommands() -> some Commands {
        CommandMenu("Playback") {
            playPauseMenuItem()
            
            Divider()
            
            shuffleMenuItem()
            repeatMenuItem()
            
            Divider()
            
            navigationMenuItems()
            
            Divider()
            
            volumeMenuItems()
        }
    }
    
    private func playPauseMenuItem() -> some View {
        Button {
            if appCoordinator.playbackManager.currentTrack != nil {
                appCoordinator.playbackManager.togglePlayPause()
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Play/Pause",
                    systemImage: Icons.playPauseFill
                )
            } else {
                Text("Play/Pause")
            }
        }
        .keyboardShortcut(" ", modifiers: [])
        .disabled(appCoordinator.playbackManager.currentTrack == nil)
    }
    
    private func shuffleMenuItem() -> some View {
        Toggle(isOn: Binding(
            get: { appCoordinator.playlistManager.isShuffleEnabled },
            set: { _ in
                appCoordinator.playlistManager.toggleShuffle()
                menuUpdateTrigger = UUID()
            }
        )) {
            if #available(macOS 26.0, *) {
                Label("Shuffle", systemImage: Icons.shuffleFill)
            } else {
                Text("Shuffle")
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .id(menuUpdateTrigger)
    }
    
    private func repeatMenuItem() -> some View {
        Button {
            appCoordinator.playlistManager.toggleRepeatMode()
            menuUpdateTrigger = UUID()
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    repeatModeLabel,
                    systemImage: Icons.repeatFill
                )
            } else {
                Text(repeatModeLabel)
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .id(menuUpdateTrigger)
    }
    
    @ViewBuilder
    private func navigationMenuItems() -> some View {
        nextMenuItem()
        previousMenuItem()
        seekForwardMenuItem()
        seekBackwardMenuItem()
    }
    
    private func nextMenuItem() -> some View {
        Button {
            appCoordinator.playlistManager.playNextTrack()
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Next",
                    systemImage: Icons.nextFill
                )
            } else {
                Text("Next")
            }
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(appCoordinator.playbackManager.currentTrack == nil)
    }
    
    private func previousMenuItem() -> some View {
        Button {
            appCoordinator.playlistManager.playPreviousTrack()
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Previous",
                    systemImage: Icons.previousFIll
                )
            } else {
                Text("Previous")
            }
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(appCoordinator.playbackManager.currentTrack == nil)
    }
    
    private func seekForwardMenuItem() -> some View {
        Button {
            if let currentTrack = appCoordinator.playbackManager.currentTrack {
                let newTime = min(
                    appCoordinator.playbackManager.actualCurrentTime + 10,
                    currentTrack.duration
                )
                appCoordinator.playbackManager.seekTo(time: newTime)
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Seek Forward",
                    systemImage: Icons.forwardFill
                )
            } else {
                Text("Seek Forward")
            }
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
        .disabled(appCoordinator.playbackManager.currentTrack == nil)
    }
    
    private func seekBackwardMenuItem() -> some View {
        Button {
            if appCoordinator.playbackManager.currentTrack != nil {
                let newTime = max(
                    appCoordinator.playbackManager.actualCurrentTime - 10,
                    0
                )
                appCoordinator.playbackManager.seekTo(time: newTime)
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Seek Backward",
                    systemImage: Icons.backwardFill
                )
            } else {
                Text("Seek Backward")
            }
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
        .disabled(appCoordinator.playbackManager.currentTrack == nil)
    }
    
    @ViewBuilder
    private func volumeMenuItems() -> some View {
        volumeUpMenuItem()
        volumeDownMenuItem()
    }
    
    private func volumeUpMenuItem() -> some View {
        Button {
            let newVolume = min(appCoordinator.playbackManager.volume + 0.05, 1.0)
            appCoordinator.playbackManager.setVolume(newVolume)
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Volume Up",
                    systemImage: Icons.volumeIncrease
                )
            } else {
                Text("Volume Up")
            }
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
    }
    
    private func volumeDownMenuItem() -> some View {
        Button {
            let newVolume = max(appCoordinator.playbackManager.volume - 0.05, 0.0)
            appCoordinator.playbackManager.setVolume(newVolume)
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Volume Down",
                    systemImage: Icons.volumeDecrease
                )
            } else {
                Text("Volume Down")
            }
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
    }
    
    // MARK: - Window Menu Commands
    
    @CommandsBuilder
    private func windowMenuCommands() -> some Commands {
        CommandGroup(before: .windowList) {
            Button {
                openWindow(id: "equalizer")
            } label: {
                if #available(macOS 26.0, *) {
                    Label(
                        "Equalizer",
                        systemImage: "slider.vertical.3"
                    )
                } else {
                    Text("Equalizer")
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button {
                MiniPlayerWindowManager.shared.show()
            } label: {
                if #available(macOS 26.0, *) {
                    Label(
                        "Mini Player",
                        systemImage: Icons.miniPlayer
                    )
                } else {
                    Text("Mini Player")
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(appCoordinator.playbackManager.currentTrack == nil)

            Button {
                NotificationCenter.default.post(name: .toggleImmersivePlayer, object: nil)
            } label: {
                if #available(macOS 26.0, *) {
                    Label(
                        "Immersive Mode",
                        systemImage: Icons.immersive
                    )
                } else {
                    Text("Immersive Mode")
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(appCoordinator.playbackManager.currentTrack == nil)

            Divider()
        }
    }
    
    // MARK: - View Menu Commands
    
    @CommandsBuilder
    private func viewMenuCommands() -> some Commands {
        CommandGroup(after: .toolbar) {
            focusSearchMenuItem()
            foldersTabToggle()
            miniPlayerOnTopToggle()
        }
    }

    private func miniPlayerOnTopToggle() -> some View {
        Toggle(isOn: $miniPlayerAlwaysOnTop) {
            if #available(macOS 26.0, *) {
                Label("Keep Mini Player always on top", systemImage: Icons.miniPlayer)
            } else {
                Text("Keep Mini Player always on top")
            }
        }
    }
    
    private func focusSearchMenuItem() -> some View {
        Button {
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Search Library",
                    systemImage: Icons.magnifyingGlass
                )
            } else {
                Text("Search Library")
            }
        }
        .keyboardShortcut("f", modifiers: .command)
    }
    
    private func foldersTabToggle() -> some View {
        Toggle(isOn: $showFoldersTab) {
            if #available(macOS 26.0, *) {
                Label("Folders Tab", systemImage: Icons.folderFill)
            } else {
                Text("Folders Tab")
            }
        }
        .keyboardShortcut("f", modifiers: [.command, .option, .shift])
    }
    
    // MARK: - Help Menu Commands
    
    @CommandsBuilder
    private func helpMenuCommands() -> some Commands {
        CommandGroup(replacing: .help) {
            projectHomepageMenuItem()
            sponsorProjectMenuItem()
            Divider()
            helpMenuItem()
        }
    }
    
    private func projectHomepageMenuItem() -> some View {
        Button {
            if let url = URL(string: About.appWebsite) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Project Homepage",
                    systemImage: "globe"
                )
            } else {
                Text("Project Homepage")
            }
        }
    }
    
    private func sponsorProjectMenuItem() -> some View {
        Button {
            if let url = URL(string: About.sponsor) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Support Development",
                    systemImage: "dollarsign.circle"
                )
            } else {
                Text("Support Development")
            }
        }
    }
    
    private func helpMenuItem() -> some View {
        Button {
            if let url = URL(string: About.appWiki) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    "Petrichor User Guide",
                    systemImage: "book.pages"
                )
            } else {
                Text("Petrichor User Guide")
            }
        }
        .keyboardShortcut("?", modifiers: .command)
    }
    
    // MARK: - Helper Properties
    
    private var repeatModeLabel: String {
        switch appCoordinator.playlistManager.repeatMode {
        case .off: return String(appLocalized: "Repeat: Off")
        case .one: return String(appLocalized: "Repeat: Current Track")
        case .all: return String(appLocalized: "Repeat: All")
        }
    }
}
