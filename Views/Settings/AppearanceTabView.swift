import AppKit
import SwiftUI

struct AppearanceTabView: View {
    @EnvironmentObject private var localizationSettings: LocalizationSettings

    @AppStorage("colorMode")
    private var colorMode: ColorMode = .auto

    @AppStorage("showFoldersTab")
    private var showFoldersTab = false

    @AppStorage("showTrackTechnicalInfo")
    private var showTrackTechnicalInfo = true

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @AppStorage("playerBarBackgroundStyle")
    private var playerBarBackgroundStyle: PlayerBarBackgroundStyle = .fullWidth

    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true

    @AppStorage("tintNowPlayingBackground")
    private var tintNowPlayingBackground = true

    @AppStorage("miniPlayerAlwaysOnTop")
    private var miniPlayerAlwaysOnTop = false

    @AppStorage("desktopLyricsEnabled")
    private var desktopLyricsEnabled = false

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false

    @AppStorage("desktopLyricsFontName")
    private var desktopLyricsFontName = DesktopLyricsSettings.systemFontName

    @AppStorage("desktopLyricsFontSize")
    private var desktopLyricsFontSize = 28.0

    @State private var showTrackInfoHelp = false

    /// Leading inset used to nest the options that depend on the master tint toggle.
    private let dependentIndent: CGFloat = 20

    private var desktopLyricsFontFamilies: [String] {
        [DesktopLyricsSettings.systemFontName] + NSFontManager.shared.availableFontFamilies.sorted()
    }

    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { localizationSettings.appLanguage },
            set: { localizationSettings.select($0) }
        )
    }

    enum ColorMode: String, CaseIterable, TabbedItem {
        case light = "Light"
        case dark = "Dark"
        case auto = "Auto"

        var displayName: String {
            switch self {
            case .light: return String(localized: "Light")
            case .dark: return String(localized: "Dark")
            case .auto: return String(localized: "Auto")
            }
        }

        var icon: String {
            switch self {
            case .light:
                return "sun.max.fill"
            case .dark:
                return "moon.fill"
            case .auto:
                return "circle.lefthalf.filled"
            }
        }

        var title: String { self.displayName }
    }

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Show folders tab in main window", isOn: $showFoldersTab)
                    .help("Shows Folders tab within the main window to browse music directly from added folders")

                Toggle(isOn: $showTrackTechnicalInfo) {
                    HStack(spacing: 4) {
                        Text("Show audio format details")
                        infoButton
                    }
                }
                .help("Shows the playing track's codec, bitrate, sample rate, and channels in the player")

                Toggle("Keep Mini Player on top of all other windows", isOn: $miniPlayerAlwaysOnTop)
                    .help("Floats the Mini Player window above windows from other apps")
            }

            Section("Desktop Lyrics") {
                Toggle("Show desktop lyrics", isOn: $desktopLyricsEnabled)
                    .help("Displays synced lyrics in a floating desktop window")

                Toggle("Lock desktop lyrics", isOn: $desktopLyricsClickThrough)
                    .help("Lets mouse clicks pass through desktop lyrics")
                    .disabled(!desktopLyricsEnabled)

                Picker("Font", selection: $desktopLyricsFontName) {
                    ForEach(desktopLyricsFontFamilies, id: \.self) { fontName in
                        Text(fontName == DesktopLyricsSettings.systemFontName ? String(localized: "System Font") : fontName)
                            .tag(fontName)
                    }
                }
                .disabled(!desktopLyricsEnabled)

                HStack {
                    Slider(value: $desktopLyricsFontSize, in: 18...48, step: 1) {
                        Text("Size")
                    }

                    Text("\(Int(desktopLyricsFontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!desktopLyricsEnabled)
            }

            Section("Customization") {
                Picker("Language", selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }

                HStack {
                    Text("Color mode")
                    Spacer()
                    TabbedButtons(
                        items: ColorMode.allCases,
                        selection: $colorMode,
                        style: .flexible
                    )
                    .frame(width: 200)
                }

                Toggle("Tint interface with album artwork colors", isOn: $useArtworkColors)
                    .help("Applies a gradient background derived from album artwork colors across the app")

                Picker("Player bar background style", selection: $playerBarBackgroundStyle) {
                    ForEach(PlayerBarBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!useArtworkColors)
                .padding(.leading, dependentIndent)

                Toggle("Color playback and audio controls", isOn: $tintPlaybackControls)
                    .help("Uses the album artwork's dominant color for playback and volume controls in the player, Mini Player, and Immersive mode")
                    .disabled(!useArtworkColors)
                    .padding(.leading, dependentIndent)

                Toggle("Use artwork background in Mini Player and Immersive mode", isOn: $tintNowPlayingBackground)
                    .help("Uses album artwork colors as the background in Mini Player and Immersive mode")
                    .disabled(!useArtworkColors)
                    .padding(.leading, dependentIndent)
            }
        }
        .formStyle(.grouped)
        .padding(5)
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
        .onChange(of: colorMode) { _, newValue in
            updateAppearance(newValue)
        }
        .onAppear {
            updateAppearance(colorMode)
        }
    }

    private var infoButton: some View {
        Button { showTrackInfoHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTrackInfoHelp, arrowEdge: .trailing) {
            Text("Shows small badges under the playing track for its audio details like codec (FLAC, MP3, etc.), bitrate, sample rate, and channels.")
                .font(.system(size: 12))
                .padding(10)
                .frame(width: 240)
        }
    }

    private func updateAppearance(_ mode: ColorMode) {
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApp.appearance = nil
        }
    }
}

#Preview {
    AppearanceTabView()
        .frame(width: 600, height: 500)
        .environmentObject(LocalizationSettings())
}
