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
                    DispatchQueue.main.async {
                        appCoordinator.menuBarManager.refreshMenu()
                        refreshMainMenuLocalizedTitles()
                    }
                }
                .onAppear {
                    refreshMainMenuLocalizedTitles()
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
        WindowGroup(String(appLocalized: "Equalizer"), id: "equalizer") {
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
                localizedMenuLabel("About Petrichor", systemImage: Icons.infoCircle)
            } else {
                localizedMenuText("About Petrichor")
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
                localizedMenuLabel("Settings", systemImage: Icons.settings)
            } else {
                localizedMenuText("Settings")
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
                    localizedMenuLabel("New", systemImage: "plus.square")
                } else {
                    localizedMenuText("New")
                }
            }
            
            Divider()
            
            // Library submenu
            Menu {
                addFolderMenuItem()
                refreshLibraryMenuItem()
            } label: {
                if #available(macOS 26.0, *) {
                    localizedMenuLabel("Library", image: "custom.music.note.rectangle.stack")
                } else {
                    localizedMenuText("Library")
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
                localizedMenuLabel("Close", systemImage: "xmark")
            } else {
                localizedMenuText("Close")
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
                localizedMenuLabel("Playlist", systemImage: Icons.musicNoteList)
            } else {
                localizedMenuText("Playlist")
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
                localizedMenuLabel("Playlist from Selection", systemImage: Icons.musicNoteList)
            } else {
                localizedMenuText("Playlist from Selection")
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
                localizedMenuLabel("Add Folder(s) to Library", systemImage: Icons.folderBadgePlus)
            } else {
                localizedMenuText("Add Folder(s) to Library")
            }
        }
        .keyboardShortcut("o", modifiers: .command)
    }

    private func refreshLibraryMenuItem() -> some View {
        Button {
            appCoordinator.libraryManager.refreshLibrary()
        } label: {
            if #available(macOS 26.0, *) {
                localizedMenuLabel("Refresh Library Folders", systemImage: Icons.arrowClockwise)
            } else {
                localizedMenuText("Refresh Library Folders")
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }

    // MARK: - Playback Menu Commands
    
    @CommandsBuilder
    private func playbackMenuCommands() -> some Commands {
        CommandMenu(String(appLocalized: "Playback")) {
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
                    title: { localizedMenuText("Play/Pause") },
                    icon: { Image(systemName: Icons.playPauseFill) }
                )
            } else {
                localizedMenuText("Play/Pause")
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
                localizedMenuLabel("Shuffle", systemImage: Icons.shuffleFill)
            } else {
                localizedMenuText("Shuffle")
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
                menuLabel(repeatModeLabel, systemImage: Icons.repeatFill)
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
                    title: { localizedMenuText("Next") },
                    icon: { Image(systemName: Icons.nextFill) }
                )
            } else {
                localizedMenuText("Next")
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
                    title: { localizedMenuText("Previous") },
                    icon: { Image(systemName: Icons.previousFIll) }
                )
            } else {
                localizedMenuText("Previous")
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
                    title: { localizedMenuText("Seek Forward") },
                    icon: { Image(systemName: Icons.forwardFill) }
                )
            } else {
                localizedMenuText("Seek Forward")
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
                    title: { localizedMenuText("Seek Backward") },
                    icon: { Image(systemName: Icons.backwardFill) }
                )
            } else {
                localizedMenuText("Seek Backward")
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
                    title: { localizedMenuText("Volume Up") },
                    icon: { Image(systemName: Icons.volumeIncrease) }
                )
            } else {
                localizedMenuText("Volume Up")
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
                    title: { localizedMenuText("Volume Down") },
                    icon: { Image(systemName: Icons.volumeDecrease) }
                )
            } else {
                localizedMenuText("Volume Down")
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
                        title: { localizedMenuText("Equalizer") },
                        icon: { Image(systemName: "slider.vertical.3") }
                    )
                } else {
                    localizedMenuText("Equalizer")
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button {
                MiniPlayerWindowManager.shared.show()
            } label: {
                if #available(macOS 26.0, *) {
                    Label(
                        title: { localizedMenuText("Mini Player") },
                        icon: { Image(systemName: Icons.miniPlayer) }
                    )
                } else {
                    localizedMenuText("Mini Player")
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(appCoordinator.playbackManager.currentTrack == nil)

            Button {
                NotificationCenter.default.post(name: .toggleImmersivePlayer, object: nil)
            } label: {
                if #available(macOS 26.0, *) {
                    Label(
                        title: { localizedMenuText("Immersive Mode") },
                        icon: { Image(systemName: Icons.immersive) }
                    )
                } else {
                    localizedMenuText("Immersive Mode")
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
                localizedMenuLabel("Keep Mini Player always on top", systemImage: Icons.miniPlayer)
            } else {
                localizedMenuText("Keep Mini Player always on top")
            }
        }
    }
    
    private func focusSearchMenuItem() -> some View {
        Button {
            NotificationCenter.default.post(name: .focusSearchField, object: nil)
        } label: {
            if #available(macOS 26.0, *) {
                Label(
                    title: { localizedMenuText("Search Library") },
                    icon: { Image(systemName: Icons.magnifyingGlass) }
                )
            } else {
                localizedMenuText("Search Library")
            }
        }
        .keyboardShortcut("f", modifiers: .command)
    }
    
    private func foldersTabToggle() -> some View {
        Toggle(isOn: $showFoldersTab) {
            if #available(macOS 26.0, *) {
                localizedMenuLabel("Folders Tab", systemImage: Icons.folderFill)
            } else {
                localizedMenuText("Folders Tab")
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
                    title: { localizedMenuText("Project Homepage") },
                    icon: { Image(systemName: "globe") }
                )
            } else {
                localizedMenuText("Project Homepage")
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
                    title: { localizedMenuText("Support Development") },
                    icon: { Image(systemName: "dollarsign.circle") }
                )
            } else {
                localizedMenuText("Support Development")
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
                    title: { localizedMenuText("Petrichor User Guide") },
                    icon: { Image(systemName: "book.pages") }
                )
            } else {
                localizedMenuText("Petrichor User Guide")
            }
        }
        .keyboardShortcut("?", modifiers: .command)
    }
    
    // MARK: - Helper Properties

    private func localizedMenuString(_ key: String.LocalizationValue) -> String {
        _ = localizationSettings.appLanguage
        return String(appLocalized: key)
    }

    private func localizedMenuText(_ key: String.LocalizationValue) -> Text {
        Text(localizedMenuString(key))
    }

    private func localizedMenuLabel(_ key: String.LocalizationValue, systemImage: String) -> some View {
        Label {
            localizedMenuText(key)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func localizedMenuLabel(_ key: String.LocalizationValue, image: String) -> some View {
        Label {
            localizedMenuText(key)
        } icon: {
            Image(image)
        }
    }

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func refreshMainMenuLocalizedTitles() {
        guard let mainMenu = NSApp.mainMenu else { return }

        for update in mainMenuTitleUpdates {
            updateMenuTitles(
                in: mainMenu,
                matching: Set(update.candidates),
                to: update.title
            )
        }

        updateAppNamedMenuTitles(in: mainMenu)
    }

    private var mainMenuTitleUpdates: [(candidates: [String], title: String)] {
        [
            (["File", "文件"], localizedMenuString("File")),
            (["Edit", "编辑"], localizedMenuString("Edit")),
            (["View", "显示", "视图"], localizedMenuString("View")),
            (["Playback", "播放"], localizedMenuString("Playback")),
            (["Window", "窗口"], localizedMenuString("Window")),
            (["Help", "帮助"], localizedMenuString("Help")),
            (["About Petrichor", "关于 Petrichor"], localizedMenuString("About Petrichor")),
            (["Settings", "设置"], localizedMenuString("Settings")),
            (["Services", "服务"], localizedMenuString("Services")),
            (["Hide Petrichor", "隐藏 Petrichor"], localizedMenuString("Hide Petrichor")),
            (["Hide Others", "隐藏其他"], localizedMenuString("Hide Others")),
            (["Show All", "全部显示"], localizedMenuString("Show All")),
            (["Quit Petrichor", "退出 Petrichor"], localizedMenuString("Quit Petrichor")),
            (["Undo", "撤销"], localizedMenuString("Undo")),
            (["Redo", "重做"], localizedMenuString("Redo")),
            (["Cut", "剪切"], localizedMenuString("Cut")),
            (["Copy", "复制"], localizedMenuString("Copy")),
            (["Paste", "粘贴"], localizedMenuString("Paste")),
            (["Select All", "全选"], localizedMenuString("Select All")),
            (["New", "新建"], localizedMenuString("New")),
            (["Library", "资料库"], localizedMenuString("Library")),
            (["Close", "关闭"], localizedMenuString("Close")),
            (["Close Window", "关闭窗口"], localizedMenuString("Close Window")),
            (["Playlist", "播放列表"], localizedMenuString("Playlist")),
            (["Playlist from Selection", "从所选内容创建播放列表"], localizedMenuString("Playlist from Selection")),
            (["Add Folder(s) to Library", "将文件夹添加到资料库"], localizedMenuString("Add Folder(s) to Library")),
            (["Refresh Library Folders", "刷新资料库文件夹"], localizedMenuString("Refresh Library Folders")),
            (["Play/Pause", "播放/暂停"], localizedMenuString("Play/Pause")),
            (["Shuffle", "随机播放"], localizedMenuString("Shuffle")),
            (["Repeat: Off", "重复：关闭"], localizedMenuString("Repeat: Off")),
            (["Repeat: Current Track", "重复：当前歌曲"], localizedMenuString("Repeat: Current Track")),
            (["Repeat: All", "重复：全部"], localizedMenuString("Repeat: All")),
            (["Next", "下一首"], localizedMenuString("Next")),
            (["Previous", "上一首"], localizedMenuString("Previous")),
            (["Seek Forward", "前进"], localizedMenuString("Seek Forward")),
            (["Seek Backward", "后退"], localizedMenuString("Seek Backward")),
            (["Volume Up", "提高音量"], localizedMenuString("Volume Up")),
            (["Volume Down", "降低音量"], localizedMenuString("Volume Down")),
            (["Equalizer", "均衡器"], localizedMenuString("Equalizer")),
            (["Mini Player", "迷你播放器"], localizedMenuString("Mini Player")),
            (["Immersive Mode", "沉浸模式"], localizedMenuString("Immersive Mode")),
            (["Keep Mini Player always on top", "迷你播放器始终置顶"], localizedMenuString("Keep Mini Player always on top")),
            (["Search Library", "搜索资料库"], localizedMenuString("Search Library")),
            (["Folders Tab", "文件夹标签页"], localizedMenuString("Folders Tab")),
            (["Minimize", "最小化"], localizedMenuString("Minimize")),
            (["Zoom", "缩放"], localizedMenuString("Zoom")),
            (["Bring All to Front", "全部前置", "全部置于前台"], localizedMenuString("Bring All to Front")),
            (["Enter Full Screen", "进入全屏幕", "进入全屏"], localizedMenuString("Enter Full Screen")),
            (["Exit Full Screen", "退出全屏幕", "退出全屏"], localizedMenuString("Exit Full Screen")),
            (["Project Homepage", "项目主页"], localizedMenuString("Project Homepage")),
            (["Support Development", "支持开发"], localizedMenuString("Support Development")),
            (["Petrichor User Guide", "Petrichor 用户指南"], localizedMenuString("Petrichor User Guide"))
        ]
    }

    private func updateMenuTitles(in menu: NSMenu, matching candidates: Set<String>, to title: String) {
        for item in menu.items {
            if candidates.contains(item.title) {
                item.title = title
                item.submenu?.title = title
            }

            if let submenu = item.submenu {
                updateMenuTitles(in: submenu, matching: candidates, to: title)
            }
        }
    }

    private func updateAppNamedMenuTitles(in menu: NSMenu) {
        for appName in appMenuNameCandidates {
            updateMenuTitles(
                in: menu,
                matching: Set(["Hide \(appName)", "隐藏 \(appName)"]),
                to: "\(localizedMenuString("Hide")) \(appName)"
            )
            updateMenuTitles(
                in: menu,
                matching: Set(["Quit \(appName)", "退出 \(appName)"]),
                to: "\(localizedMenuString("Quit")) \(appName)"
            )
        }
    }

    private var appMenuNameCandidates: [String] {
        [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            ProcessInfo.processInfo.processName,
            "Petrichor",
            "Petrichor Dev"
        ]
        .compactMap { $0 }
        .reduce(into: [String]()) { names, name in
            if !names.contains(name) {
                names.append(name)
            }
        }
    }
    
    private var repeatModeLabel: String {
        switch appCoordinator.playlistManager.repeatMode {
        case .off: return String(appLocalized: "Repeat: Off")
        case .one: return String(appLocalized: "Repeat: Current Track")
        case .all: return String(appLocalized: "Repeat: All")
        }
    }
}
