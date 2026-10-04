//
// ImmersiveView
//
// An immersive mode showing now playing view along with ability to show
// current playback queue or lyrics on the side.
// Presented as an in-window overlay (a ZStack layer in ContentView) that
// covers the entire main window edge-to-edge.
//

import SwiftUI
import AppKit

private enum ImmersivePanel: String {
    case none
    case queue
    case lyrics
}

private let immersivePanelStateKey = "immersivePanelState"

private struct ImmersiveLayout {
    let scale: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let blockWidth: CGFloat
    let panelWidth: CGFloat
    let artSide: CGFloat
    let blockHeight: CGFloat
    let lyricsHeight: CGFloat

    var titleFontSize: CGFloat { 22 * scale }
    var artistFontSize: CGFloat { 16 * scale }
    var titleSpacing: CGFloat { 6 * scale }
    var columnSpacing: CGFloat { 20 * scale }
    var controlsSpacing: CGFloat { 16 * scale }
    var controlsScale: CGFloat { min(scale * 1.3, 2.6) }
    var cornerRadius: CGFloat { 12 * scale }
    var headerHorizontalPadding: CGFloat { 16 * scale }
    var headerVerticalPadding: CGFloat { 14 * scale }
    var headerSpacing: CGFloat { 12 * scale }
    var headerTitleFontSize: CGFloat { 15 * scale }
    var headerCaptionFontSize: CGFloat { 12 * scale }
    var headerIconSize: CGFloat { 13 * scale }
}

struct ImmersiveView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager

    /// Owned by ContentView; the close button / Esc set this false to dismiss.
    @Binding var isPresented: Bool

    @Environment(\.colorScheme)
    private var colorScheme

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true
    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true
    @AppStorage("tintNowPlayingBackground")
    private var tintNowPlayingBackground = true

    @AppStorage("immersiveLyricsFontName")
    private var immersiveLyricsFontName = LyricsFontSettings.systemFontName

    @AppStorage("immersiveLyricsFontSize")
    private var immersiveLyricsFontSize = 20.0

    @AppStorage(immersivePanelStateKey)
    private var panel: ImmersivePanel = .none
    @State private var cachedArtwork: NSImage?
    @State private var currentTrackId: UUID?
    @State private var gradientColors: [Color] = []

    // Cached alongside gradientColors so the ~10 text/border call sites read a
    // stored value instead of re-deriving luminance on every body evaluation.
    @State private var adaptiveText: Color = .white
    @State private var showingClearConfirmation = false

    // Gates the gradient crossfade so the first (seeded) gradient appears instantly
    // and slides up with the view, rather than fading in independently. Later track
    // changes do crossfade.
    @State private var didAppear = false

    /// Artwork/gradient/adaptive color are seeded from ContentView so they're present
    /// on the very first frame; otherwise they'd populate in `onAppear` (after
    /// insertion) and pop/fade in while the view is sliding up.
    init(isPresented: Binding<Bool>, artwork: NSImage?, gradient: [Color], trackID: UUID?, isDarkMode: Bool) {
        _isPresented = isPresented
        _cachedArtwork = State(initialValue: artwork)
        _gradientColors = State(initialValue: gradient)
        _currentTrackId = State(initialValue: trackID)
        _adaptiveText = State(initialValue: Self.adaptiveTextColor(for: gradient, isDark: isDarkMode))
    }

    private var hasCurrentTrack: Bool {
        playbackManager.currentTrack != nil
    }

    private var controlsUseArtworkTint: Bool {
        useArtworkColors && tintPlaybackControls
    }

    private var backgroundUsesArtwork: Bool {
        useArtworkColors && tintNowPlayingBackground
    }

    private var artworkTint: Color {
        NowPlayingArtwork.tint(for: playbackManager.currentTrack, useArtworkTint: controlsUseArtworkTint)
    }

    /// Whether the immersive background reads as dark: the gradient (under its scrim)
    /// when tinting is on, or the plain window background's appearance when it's off.
    /// Drives both the adaptive text and whether the tinted controls brighten/deepen.
    private var backgroundIsDark: Bool {
        Self.backgroundIsDark(for: gradientColors, isDark: colorScheme == .dark)
    }

    /// Legible, mode-adjusted dominant color for the secondary controls, brightened or
    /// deepened to match the actual background rather than always assuming dark.
    private var controlColor: Color {
        NowPlayingArtwork.controlColor(
            for: playbackManager.currentTrack,
            useArtworkTint: controlsUseArtworkTint,
            isDarkBackground: backgroundIsDark
        )
    }

    /// Prev/next icon color: the artwork control color when tinting is on, otherwise
    /// the adaptive neutral so it stays legible on the plain window background.
    private var transportColor: Color {
        controlsUseArtworkTint ? controlColor : adaptiveText
    }

    /// Whether the background reads as dark: with no gradient (tinting off) the plain
    /// window background follows the appearance; otherwise it's the gradient's average
    /// luminance under the background's black scrim.
    private static func backgroundIsDark(for gradient: [Color], isDark: Bool) -> Bool {
        guard !gradient.isEmpty else { return isDark }
        let average = gradient.reduce(CGFloat(0)) { $0 + NowPlayingArtwork.luminance(of: $1) * 0.6 } / CGFloat(gradient.count)
        return average <= 0.55
    }

    /// White or black foreground, whichever stays legible against the background.
    private static func adaptiveTextColor(for gradient: [Color], isDark: Bool) -> Color {
        backgroundIsDark(for: gradient, isDark: isDark) ? .white : .black
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                content(in: geo)
                floatingToolbar
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(escapeKeyCatcher)
        .onExitCommand { close() }
        .onAppear {
            // Artwork/gradient/adaptive color are already seeded via init. Open the
            // gradient-crossfade gate after the first frame so subsequent track
            // changes crossfade while the initial gradient slid in untouched.
            DispatchQueue.main.async { didAppear = true }
        }
        .onChange(of: playbackManager.currentTrack?.id) {
            refreshArtwork()
            updateGradientColors()
        }
        .onChange(of: playbackManager.currentTrack?.artworkData?.count) {
            refreshArtwork()
            updateGradientColors()
        }
        .onChange(of: colorScheme) {
            updateGradientColors()
        }
        .onChange(of: backgroundUsesArtwork) {
            updateGradientColors()
        }
        .clearQueueConfirmation(isPresented: $showingClearConfirmation) {
            playlistManager.clearQueue()
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            if !gradientColors.isEmpty {
                Color.black

                GradientBackground(colors: gradientColors)
                    .animation(didAppear ? .easeInOut(duration: AnimationDuration.standardDuration) : nil, value: gradientColors)

                if let cachedArtwork {
                    GeometryReader { geometry in
                        Image(nsImage: cachedArtwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .blur(radius: 90)
                            .scaleEffect(1.2)
                            .opacity(0.3)
                            .clipped()
                    }
                    .allowsHitTesting(false)
                }

                Color.black.opacity(0.4)
            } else {
                // Tinting off: match the app's standard window background rather than a
                // forced dark backdrop; the controls/text adapt via `adaptiveText`.
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private func content(in geo: GeometryProxy) -> some View {
        let layout = makeLayout(for: geo.size)

        return HStack(alignment: .center, spacing: layout.spacing) {
            nowPlayingColumn(layout: layout)

            if panel != .none {
                panelBox(layout: layout)
                    .frame(width: layout.panelWidth, height: panel == .lyrics ? layout.lyricsHeight : layout.blockHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, layout.padding)
        .padding(.vertical, 60 * layout.scale)
        .animation(.easeInOut(duration: AnimationDuration.standardDuration), value: panel)
    }

    private func makeLayout(for size: CGSize) -> ImmersiveLayout {
        let scale = max(0.65, min(min(size.width / 1440, size.height / 900), 2.4))
        let padding = max(24, min(size.width * 0.065, 110 * scale))
        let spacing = 80 * scale
        let availableWidth = max(0, size.width - padding * 2 - (panel == .none ? 0 : spacing))
        let blockWidth = min(520 * scale, panel == .none ? availableWidth : availableWidth * 0.43)
        let panelWidth = max(0, availableWidth - blockWidth)
        let reservedHeight = 196 * scale
        let artSide = max(0, min(480 * scale, blockWidth, size.height - padding * 2 - reservedHeight))
        let blockHeight = artSide + reservedHeight

        return ImmersiveLayout(
            scale: scale,
            padding: padding,
            spacing: spacing,
            blockWidth: blockWidth,
            panelWidth: panelWidth,
            artSide: artSide,
            blockHeight: blockHeight,
            lyricsHeight: max(0, size.height - 120 * scale)
        )
    }

    private func nowPlayingColumn(layout: ImmersiveLayout) -> some View {
        VStack(spacing: layout.columnSpacing) {
            artworkView(side: layout.artSide, cornerRadius: layout.cornerRadius)

            VStack(alignment: .leading, spacing: layout.titleSpacing) {
                Text(playbackManager.currentTrack?.title ?? String(appLocalized: "Not Playing"))
                    .font(.system(size: layout.titleFontSize, weight: .semibold))
                    .foregroundColor(adaptiveText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(playbackManager.currentTrack?.displayArtist ?? "")
                    .font(.system(size: layout.artistFontSize))
                    .foregroundColor(adaptiveText.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: layout.artSide, alignment: .leading)

            VStack(spacing: layout.controlsSpacing) {
                NowPlayingProgressBar(
                    accent: adaptiveText.opacity(0.8),
                    neutral: adaptiveText,
                    scale: layout.controlsScale,
                    usesImmersiveStyle: true
                )
                NowPlayingControlsView(
                    tint: artworkTint,
                    accent: controlColor,
                    transport: transportColor,
                    neutral: adaptiveText,
                    scale: layout.controlsScale,
                    usesImmersiveStyle: true
                )
            }
            .frame(width: layout.artSide)
        }
        .frame(width: layout.blockWidth, height: layout.blockHeight)
    }

    @ViewBuilder
    private func artworkView(side: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let image = cachedArtwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: Icons.musicNote)
                            .font(.system(size: side * 0.2, weight: .light))
                            .foregroundColor(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24 * (side / 460), x: 0, y: 12 * (side / 460))
    }

    // MARK: - Panel Box

    private func panelBox(layout: ImmersiveLayout) -> some View {
        VStack(spacing: 0) {
            // Lyrics don't need a header; the queue keeps its count / clear action.
            if panel == .queue {
                panelHeader(layout: layout)
                Divider()
                    .background(adaptiveText)
                    .opacity(0.2)
            }
            panelContent(layout: layout)
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .stroke(adaptiveText.opacity(0.15), lineWidth: 0)
        )
    }

    @ViewBuilder
    private func panelContent(layout: ImmersiveLayout) -> some View {
        switch panel {
        case .queue:
            PlayQueueContent(
                accentColor: artworkTint,
                primaryTextColor: adaptiveText,
                secondaryTextColor: adaptiveText.opacity(0.6),
                scale: layout.scale
            )
        case .lyrics:
            TrackLyricsContent(
                fontName: immersiveLyricsFontName == LyricsFontSettings.systemFontName ? nil : immersiveLyricsFontName,
                fontSize: CGFloat(immersiveLyricsFontSize) * layout.scale * 1.8,
                activeColor: adaptiveText,
                inactiveColor: adaptiveText.opacity(0.6),
                usesImmersiveStyle: true
            )
        case .none:
            EmptyView()
        }
    }

    // Only rendered for the queue panel (lyrics shows no header), so it's queue-specific.
    private func panelHeader(layout: ImmersiveLayout) -> some View {
        HStack(spacing: layout.headerSpacing) {
            Text("Play Queue")
                .font(.system(size: layout.headerTitleFontSize, weight: .semibold))
                .foregroundColor(adaptiveText)

            Spacer()

            Text("\(playlistManager.currentQueue.count) tracks")
                .font(.system(size: layout.headerCaptionFontSize))
                .foregroundColor(adaptiveText.opacity(0.6))

            if !playlistManager.currentQueue.isEmpty {
                Button {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: Icons.trash)
                        .font(.system(size: layout.headerIconSize))
                        .foregroundColor(adaptiveText.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Clear Queue")
            }
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.vertical, layout.headerVerticalPadding)
    }

    // MARK: - Floating Toolbar

    private var floatingToolbar: some View {
        VStack {
            Spacer()

            panelToolbar
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(adaptiveText.opacity(0.9))
        .padding(20)
    }

    private var panelToolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                Slider(value: Binding(
                    get: { playbackManager.volume },
                    set: { playbackManager.setVolume($0) }
                ), in: 0...1)
                .labelsHidden()
                .accessibilityLabel(String(appLocalized: "Volume"))
                .frame(width: 120)
                .tint(adaptiveText)
            }
            .padding(.horizontal, 10)

            Divider()
                .frame(height: 20)
                .overlay(adaptiveText.opacity(0.15))
                .padding(.horizontal, 4)

            PanelToolbarButton(
                isActive: panel == .queue,
                isEnabled: true,
                activeTint: adaptiveText.opacity(0.18),
                activeHelp: String(appLocalized: "Hide Queue"),
                inactiveHelp: String(appLocalized: "Show Queue"),
                action: { toggle(.queue) },
                activeForeground: adaptiveText,
                inactiveForeground: adaptiveText.opacity(0.65),
                buttonSize: 34,
                label: {
                    Image(systemName: Icons.queueList)
                        .font(.system(size: 16))
                }
            )

            PanelToolbarButton(
                isActive: panel == .lyrics,
                isEnabled: hasCurrentTrack,
                activeTint: adaptiveText.opacity(0.18),
                activeHelp: String(appLocalized: "Hide Lyrics"),
                inactiveHelp: String(appLocalized: "Show Lyrics"),
                action: { toggle(.lyrics) },
                activeForeground: adaptiveText,
                inactiveForeground: adaptiveText.opacity(0.65),
                buttonSize: 34,
                label: {
                    Image(Icons.customLyrics)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
            )

            Divider()
                .frame(height: 20)
                .overlay(adaptiveText.opacity(0.15))
                .padding(.horizontal, 4)

            PanelToolbarButton(
                isActive: false,
                isEnabled: true,
                activeTint: adaptiveText.opacity(0.18),
                activeHelp: String(appLocalized: "Close Immersive Mode"),
                inactiveHelp: String(appLocalized: "Close Immersive Mode"),
                action: close,
                activeForeground: adaptiveText,
                inactiveForeground: adaptiveText.opacity(0.65),
                buttonSize: 34,
                label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                }
            )
            .accessibilityLabel(String(appLocalized: "Close Immersive Mode"))
        }
        .padding(6)
        .floatingControlClusterBackground()
    }

    // MARK: - Esc handling

    /// A zero-size hidden button bound to Esc. `onExitCommand` alone can miss the
    /// key when focus sits elsewhere in the overlay, so this guarantees the first
    /// Esc closes immersive mode. Once closed, a subsequent Esc is left to the
    /// system (e.g. to exit native fullscreen).
    private var escapeKeyCatcher: some View {
        Button(action: { close() }, label: { EmptyView() })
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func toggle(_ target: ImmersivePanel) {
        withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
            panel = (panel == target) ? .none : target
        }
    }

    private func close() {
        withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
            isPresented = false
        }
    }

    // MARK: - Helpers

    private func refreshArtwork() {
        let track = playbackManager.currentTrack
        guard track?.id != currentTrackId || cachedArtwork == nil else { return }

        currentTrackId = track?.id
        cachedArtwork = NowPlayingArtwork.image(for: track)
    }

    private func updateGradientColors() {
        gradientColors = NowPlayingArtwork.gradient(
            for: playbackManager.currentTrack,
            isDark: colorScheme == .dark,
            enabled: backgroundUsesArtwork
        )
        adaptiveText = Self.adaptiveTextColor(for: gradientColors, isDark: colorScheme == .dark)
    }
}
