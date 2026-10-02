import AppKit
import QuartzCore
import SwiftUI

struct TrackLyricsView: View {
    let onClose: () -> Void
    @EnvironmentObject private var playbackManager: PlaybackManager
    @State private var searchRequest: LyricsSearchRequest?
    @State private var displayedLyricsSource: LyricsSource?

    @AppStorage("sidePanelLyricsFontName")
    private var sidePanelLyricsFontName = LyricsFontSettings.systemFontName

    @AppStorage("sidePanelLyricsFontSize")
    private var sidePanelLyricsFontSize = LyricsFontSettings.sidePanelFontSize

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TrackLyricsContent(
                fontName: sidePanelLyricsFontName == LyricsFontSettings.systemFontName ? nil : sidePanelLyricsFontName,
                fontSize: CGFloat(sidePanelLyricsFontSize),
                usesSidePanelStyle: true
            )
        }
        .sheet(item: $searchRequest) { LyricsSearchSheet(track: $0.track) }
        .onPreferenceChange(LyricsSourcePreferenceKey.self) { displayedLyricsSource = $0 }
    }

    private var lyricsFormatLabel: String? {
        switch displayedLyricsSource {
        case .some(.ttml): "TTML"
        case .some(.ksc): "KSC"
        case .some(.lrc): "LRC"
        case .some(.srt): "SRT"
        case .some(.embedded): String(appLocalized: "Embedded Lyrics")
        case .some(.none), nil: nil
        }
    }

    // MARK: - Header
    private var header: some View {
        ListHeader(opaque: true) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: Icons.xmarkCircleFill)
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Text("Lyrics")
                    .headerTitleStyle()

                if let lyricsFormatLabel {
                    Text(verbatim: lyricsFormatLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
            }
            Spacer()
            Button {
                if let track = playbackManager.currentTrack { searchRequest = LyricsSearchRequest(track: track) }
            } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(String(appLocalized: "Search Lyrics Online..."))
            .accessibilityLabel(String(appLocalized: "Search Lyrics Online..."))
            .disabled(playbackManager.currentTrack == nil)
        }
    }
}

// MARK: - Lyrics Content (header-less, reusable)

/// The lyrics display (loading / empty / synced scroll) without any header
/// chrome, so it can be hosted inside a custom shell (e.g. the mini player) as
/// well as the main TrackLyricsView. Self-manages loading and line sync.
struct TrackLyricsContent: View {
    private struct LyricsDeletionRequest {
        let track: Track
        let source: LyricsSource
        let fileURL: URL
    }

    /// Optional font family for lyric lines. A nil value uses the system font.
    var fontName: String? = nil
    /// Font size for lyric lines. Larger hosts (e.g. immersive mode) pass a bigger
    /// value; defaults preserve the compact main-window / mini-player sizing.
    var fontSize: CGFloat = 14
    /// Color for the active (or, for untimed lyrics, every) line.
    var activeColor: Color = .primary
    /// Color for inactive lines.
    var inactiveColor: Color = .secondary
    /// Roomier typography and a stable highlight for the main-window sidebar.
    var usesSidePanelStyle = false
    /// Large, leading-aligned lines with a soft focus around the current line.
    var usesImmersiveStyle = false

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playbackManager: PlaybackManager

    @State private var lyricLines: [LyricLine] = []
    @State private var lyricsSource: LyricsSource = .none
    @State private var availableLanguages: [LyricLanguage] = [.original]
    @State private var selectedLanguage: LyricLanguage = .original
    @State private var lyricsTrackID: UUID?
    @State private var isLoading = true
    @State private var fetchFailed = false
    @State private var loadGeneration = UUID()
    @State private var searchRequest: LyricsSearchRequest?
    @State private var deletionRequest: LyricsDeletionRequest?
    @State private var hasTimedLyrics: Bool = false
    @State private var isKaraokeLyrics = false

    private var currentTrack: Track? {
        playbackManager.currentTrack
    }

    private var currentLyricsFileURL: URL? {
        guard let currentTrack, lyricsTrackID == currentTrack.id else { return nil }
        return lyricsSource.sidecarURL(for: currentTrack.url)
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if lyricLines.isEmpty {
                emptyLyricsView
            } else {
                TrackLyricsDisplay(
                    lyricLines: lyricLines,
                    lyricsTrackID: lyricsTrackID,
                    hasTimedLyrics: hasTimedLyrics,
                    isKaraokeLyrics: isKaraokeLyrics,
                    fontName: fontName,
                    fontSize: fontSize,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                    usesSidePanelStyle: usesSidePanelStyle,
                    usesImmersiveStyle: usesImmersiveStyle
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preference(
            key: LyricsSourcePreferenceKey.self,
            value: !isLoading && !lyricLines.isEmpty && lyricsTrackID == currentTrack?.id
                ? lyricsSource : nil
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(appLocalized: "Download Lyrics..."), systemImage: "text.magnifyingglass") {
                if let track = currentTrack { searchRequest = LyricsSearchRequest(track: track) }
            }
            .disabled(currentTrack == nil)

            Button(String(appLocalized: "Reload Lyrics"), systemImage: "arrow.clockwise") {
                loadLyricsForCurrentTrack(forceReload: true)
            }
            .disabled(currentTrack == nil)

            LyricsLanguageMenu(
                availableLanguages: availableLanguages,
                selectedLanguage: selectedLanguage
            )

            Button(String(appLocalized: "Copy All Lyrics"), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lyricLines.map(\.text).joined(separator: "\n"), forType: .string)
            }
            .disabled(lyricLines.isEmpty || lyricsTrackID != currentTrack?.id)

            if let currentLyricsFileURL {
                Button(String(appLocalized: "Reveal Lyrics in Finder"), systemImage: "finder") {
                    NSWorkspace.shared.selectFile(currentLyricsFileURL.path, inFileViewerRootedAtPath: "")
                }
            }

            Divider()
            Button(String(appLocalized: "Delete Current Lyrics..."), systemImage: "trash", role: .destructive) {
                guard let track = currentTrack, let fileURL = currentLyricsFileURL else { return }
                deletionRequest = LyricsDeletionRequest(track: track, source: lyricsSource, fileURL: fileURL)
            }
            .disabled(currentLyricsFileURL == nil)
        }
        .onAppear {
            loadLyricsForCurrentTrack()
            // Sample the playhead at 0.5s while lyrics are on screen for tight
            // line highlighting; the rate drops back to 1s when this view closes.
            playbackManager.setFineProgressSampling(true)
        }
        .sheet(item: $searchRequest) { LyricsSearchSheet(track: $0.track) }
        .alert(String(appLocalized: "Move current lyrics to Trash?"), isPresented: Binding(
            get: { deletionRequest != nil },
            set: { if !$0 { deletionRequest = nil } }
        )) {
            Button(String(appLocalized: "Move to Trash"), role: .destructive) {
                guard let request = deletionRequest else { return }
                deletionRequest = nil
                Task {
                    do {
                        try await TrackTrashManager.moveLyricsToTrash(for: request.track, source: request.source)
                        LyricsStore.shared.invalidate(for: request.track.url)
                        NotificationCenter.default.post(name: .downloadedLyricsDidChange, object: request.track.url)
                        NotificationManager.shared.addMessage(.info, String(appLocalized: "Lyrics moved to Trash"))
                    } catch {
                        NotificationManager.shared.addMessage(.error, String.localizedStringWithFormat(
                            String(appLocalized: "Could not move lyrics to Trash: %1$@"), error.localizedDescription
                        ))
                    }
                }
            }
            Button(String(appLocalized: "Cancel"), role: .cancel) { deletionRequest = nil }
        } message: {
            Text(verbatim: deletionRequest?.fileURL.lastPathComponent ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadedLyricsDidChange)) { notification in
            guard let url = notification.object as? URL,
                  url.standardizedFileURL == currentTrack?.url.standardizedFileURL else { return }
            loadLyricsForCurrentTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyricsScriptPreferenceDidChange)) { _ in
            // The store dropped its cache in the same notification pass, so a
            // plain reload reparses in the newly selected script.
            loadLyricsForCurrentTrack()
        }
        .onDisappear {
            playbackManager.setFineProgressSampling(false)
        }
        .onChange(of: playbackManager.currentTrack?.id) { _, _ in
            loadLyricsForCurrentTrack()
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 12) {
            ForEach([170.0, 130.0, 190.0, 110.0], id: \.self) { width in
                Capsule()
                    .fill(inactiveColor)
                    .frame(width: width, height: 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A gently pulsing skeleton of lyric lines. PhaseAnimator loops on its own
        // while visible (no extra @State) and restarts each time loading reappears.
        .phaseAnimator(
            [0.3, 0.7],
            content: { view, opacity in
                view.opacity(opacity)
            },
            animation: { _ in .easeInOut(duration: 0.85) }
        )
        .accessibilityLabel("Loading lyrics")
    }

    // MARK: - Empty Lyrics View
    private var emptyLyricsView: some View {
        VStack(spacing: 16) {
            Image(Icons.customLyrics)
                .font(.system(size: 48))
                .foregroundColor(activeColor)

            Text("No Lyrics Available")
                .font(.headline)
                .foregroundColor(activeColor)

            Button(String(appLocalized: "Search Lyrics Online...")) {
                if let track = currentTrack { searchRequest = LyricsSearchRequest(track: track) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentTrack == nil)

            if fetchFailed {
                Button {
                    loadLyricsForCurrentTrack(forceReload: true)
                } label: {
                    Label("Retry", systemImage: Icons.arrowClockwise)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helper Methods

    private func loadLyricsForCurrentTrack(forceReload: Bool = false) {
        let generation = UUID()
        loadGeneration = generation
        guard let track = currentTrack else {
            lyricLines = []
            lyricsSource = .none
            availableLanguages = [.original]
            selectedLanguage = .original
            lyricsTrackID = nil
            hasTimedLyrics = false
            isKaraokeLyrics = false
            isLoading = false
            fetchFailed = false
            return
        }

        let loadedTrackId = track.id

        if !forceReload, let cached = LyricsStore.shared.cachedLyrics(for: loadedTrackId) {
            lyricLines = cached.lines
            lyricsSource = cached.source
            availableLanguages = cached.availableLanguages
            selectedLanguage = cached.selectedLanguage
            lyricsTrackID = loadedTrackId
            hasTimedLyrics = cached.hasTimed
            isKaraokeLyrics = cached.isKaraoke
            isLoading = false
            fetchFailed = false
            return
        }

        isLoading = true
        lyricLines = []
        lyricsSource = .none
        availableLanguages = [.original]
        selectedLanguage = .original
        lyricsTrackID = nil
        fetchFailed = false
        hasTimedLyrics = false   // Reset until we know
        isKaraokeLyrics = false

        Task {
            do {
                // Shared cache + single-flight: concurrent lyrics views (main window,
                // mini player, immersive) for the same track load only once.
                let result = try await LyricsStore.shared.lyrics(
                    for: track,
                    using: libraryManager.databaseManager.dbQueue,
                    forceReload: forceReload
                )

                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId, loadGeneration == generation else { return }
                    lyricLines = result.lines
                    lyricsSource = result.source
                    availableLanguages = result.availableLanguages
                    selectedLanguage = result.selectedLanguage
                    lyricsTrackID = loadedTrackId
                    hasTimedLyrics = result.hasTimed
                    isKaraokeLyrics = result.isKaraoke
                    isLoading = false
                    fetchFailed = false
                }
            } catch {
                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId, loadGeneration == generation else { return }
                    lyricLines = []
                    lyricsSource = .none
                    availableLanguages = [.original]
                    selectedLanguage = .original
                    lyricsTrackID = nil
                    hasTimedLyrics = false
                    isKaraokeLyrics = false
                    isLoading = false
                    fetchFailed = true
                }
            }
        }
    }
}

/// Owns playback-driven highlighting and scrolling so progress samples do
/// not rebuild the native context menu attached to TrackLyricsContent.
private struct TrackLyricsDisplay: View {
    let lyricLines: [LyricLine]
    let lyricsTrackID: UUID?
    let hasTimedLyrics: Bool
    let isKaraokeLyrics: Bool
    let fontName: String?
    let fontSize: CGFloat
    let activeColor: Color
    let inactiveColor: Color
    let usesSidePanelStyle: Bool
    let usesImmersiveStyle: Bool

    @EnvironmentObject private var playbackManager: PlaybackManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentLineIndex = -1
    @State private var sampledPlaybackTime: TimeInterval = 0
    @State private var lastScrolledTrackID: UUID?
    @State private var immersiveScrollDisplacement: CGFloat = 0
    @StateObject private var boundaryScheduler = KaraokeLineBoundaryScheduler()

    // MARK: - Lyrics Content with Conditional Synced Highlight
    var body: some View {
        GeometryReader { geometry in
            lyricsScrollView(viewportSize: geometry.size)
        }
        .onAppear { refreshPlaybackSample() }
        .onChange(of: lyricLines) { _, _ in refreshPlaybackSample() }
        .onChange(of: lyricsTrackID) { _, _ in refreshPlaybackSample() }
        .onDisappear { boundaryScheduler.cancel() }
        .onChange(of: playbackManager.isPlaying) { _, isPlaying in
            transitionKaraokeBoundarySchedule(isPlaying: isPlaying)
        }
        .onReceive(playbackManager.playbackProgressState.$currentTime) { newTime in
            sampledPlaybackTime = newTime
            updateCurrentLine(for: newTime)
            resetKaraokeBoundarySchedule(at: newTime)
        }
    }

    private func lyricsScrollView(viewportSize: CGSize) -> some View {
        let horizontalPadding: CGFloat = usesImmersiveStyle ? 8 : (usesSidePanelStyle ? 16 : 20)
        let contentWidth = max(1, viewportSize.width - horizontalPadding * 2)

        return ScrollView {
            VStack(spacing: usesImmersiveStyle ? fontSize * 0.85 : (usesSidePanelStyle ? 6 : fontSize * 0.7)) {
                ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                    lyricRow(line: line, index: index, contentWidth: contentWidth)
                        // Compensate for the native scroll immediately, then let
                        // each row's visual position catch up with a spring.
                        // The anchor stays outside these transforms so wrapping
                        // and duet rows are measured at their layout positions.
                        // Keep the spring transaction out of text highlighting
                        // and karaoke timing.
                        .transaction { $0.animation = nil }
                        .modifier(ImmersiveLyricsRowMotion(
                            displacement: usesImmersiveStyle ? immersiveScrollDisplacement : 0
                        ))
                        .animation(immersiveScrollAnimation(for: index), value: immersiveScrollDisplacement)
                        .background {
                            if hasTimedLyrics, currentLineIndex == index, let lyricsTrackID {
                                LyricsScrollAnchor(
                                    trackID: lyricsTrackID,
                                    lineIndex: index,
                                    animated: lastScrolledTrackID == lyricsTrackID,
                                    viewportAnchor: usesImmersiveStyle ? 0.4 : 0.5,
                                    usesRowSpring: usesImmersiveStyle
                                ) { displacement, animatesRows in
                                    var transaction = Transaction(animation: nil)
                                    transaction.disablesAnimations = !animatesRows
                                    withTransaction(transaction) {
                                        immersiveScrollDisplacement += displacement
                                    }
                                    lastScrolledTrackID = lyricsTrackID
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, horizontalPadding)
            // Allow the first and last lines to reach the same focus position.
            .padding(.top, usesImmersiveStyle ? viewportSize.height * 0.4 : (usesSidePanelStyle ? 28 : 20))
            .padding(.bottom, usesImmersiveStyle ? viewportSize.height * 0.6 : (usesSidePanelStyle ? 28 : 20))
            .frame(maxWidth: .infinity)
            .textSelection(.disabled)
        }
        .scrollIndicators(usesImmersiveStyle ? .hidden : .automatic)
        .mask {
            if usesImmersiveStyle {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.25), location: 0.06),
                    .init(color: .black.opacity(0.75), location: 0.14),
                    .init(color: .black, location: 0.24),
                    .init(color: .black, location: 0.72),
                    .init(color: .black.opacity(0.65), location: 0.86),
                    .init(color: .black.opacity(0.2), location: 0.95),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
    }

    private func immersiveScrollAnimation(for index: Int) -> Animation? {
        guard usesImmersiveStyle, hasTimedLyrics, !reduceMotion else { return nil }
        let distance = min(4, abs(index - max(0, currentLineIndex)))
        // Give the pull time to build, with a visible overshoot and a longer
        // stagger so neighbouring lines feel attached to the focused line.
        return .spring(response: 0.82, dampingFraction: 0.62, blendDuration: 0.16)
            .delay(Double(distance) * 0.06)
    }

    @ViewBuilder
    private func lyricRow(line: LyricLine, index: Int, contentWidth: CGFloat) -> some View {
        if usesImmersiveStyle && hasTimedLyrics {
            Button {
                playbackManager.seekTo(time: line.startTime)
            } label: {
                lyricRowContent(line: line, index: index, contentWidth: contentWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            lyricRowContent(line: line, index: index, contentWidth: contentWidth)
        }
    }

    private func lyricRowContent(line: LyricLine, index: Int, contentWidth: CGFloat) -> some View {
        let isCurrent = hasTimedLyrics && (currentLineIndex == index ||
            (line.duetSide != nil && line.isActive(at: sampledPlaybackTime)))
        let alignment: Alignment = usesImmersiveStyle && line.duetSide == nil ? .leading : line.frameAlignment
        let textAlignment: TextAlignment = usesImmersiveStyle && line.duetSide == nil ? .leading : line.swiftUITextAlignment
        let horizontalPadding: CGFloat = usesSidePanelStyle ? 12 : 0
        // Reserve space on the opposite side so long duet lines wrap within their voice's area.
        let maximumTextWidth = (usesImmersiveStyle || usesSidePanelStyle) && line.duetSide != nil
            ? max(1, contentWidth - horizontalPadding * 2) * 0.75 : .infinity

        return Group {
            if isCurrent, line.timingSegments?.isEmpty == false {
                KaraokeLyricText(
                    line: line,
                    sampleTime: sampledPlaybackTime,
                    isPlaying: playbackManager.isPlaying,
                    fontName: fontName,
                    fontSize: fontSize,
                    fontWeight: usesSidePanelStyle ? .semibold : .bold,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                    lineSpacing: lyricLineSpacing,
                    textAlignment: usesImmersiveStyle && line.duetSide == nil ? .left : nil,
                    usesWordLift: usesImmersiveStyle
                )
                .frame(maxWidth: .infinity, alignment: alignment)
                .scaleEffect(usesSidePanelStyle || usesImmersiveStyle ? 1 : 1.1)
                .multilineTextAlignment(textAlignment)
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(lyricsFont(weight: usesImmersiveStyle ? .bold : (usesSidePanelStyle
                        ? (isCurrent ? .semibold : .medium)
                        : (isCurrent ? .bold : .regular))))
                    .scaleEffect(isCurrent && !usesSidePanelStyle && !usesImmersiveStyle ? 1.1 : 1.0)
                    .foregroundColor(isCurrent || ((usesSidePanelStyle || usesImmersiveStyle) && !hasTimedLyrics)
                        ? activeColor : inactiveColor)
                    .multilineTextAlignment(textAlignment)
                    .lineSpacing(lyricLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .padding(.vertical, usesImmersiveStyle ? KaraokeWordLift.maximumOffset(fontSize: fontSize) : 0)
            }
        }
        .frame(maxWidth: maximumTextWidth, alignment: alignment)
        .frame(maxWidth: .infinity, alignment: alignment)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, usesImmersiveStyle ? fontSize * 0.4 : (usesSidePanelStyle ? 10 : 0))
        // Scope the transition to visual focus; lyric timing, word fill and
        // native scrolling continue to update independently.
        .animation(usesImmersiveStyle && !reduceMotion ? .easeInOut(duration: 0.3) : nil) { content in
            content
                .blur(radius: immersiveBlurRadius(index: index, isCurrent: isCurrent))
                .opacity(immersiveOpacity(index: index, isCurrent: isCurrent))
        }
    }

    private func immersiveBlurRadius(index: Int, isCurrent: Bool) -> CGFloat {
        guard usesImmersiveStyle, hasTimedLyrics, !isCurrent, !reduceTransparency else { return 0 }
        let distance = min(5, max(1, CGFloat(abs(index - max(0, currentLineIndex)))))
        // A restrained radius preserves the shape of the letters. Use opacity
        // for depth rather than smearing distant lines into large bright blobs.
        let fontScale = min(1.3, max(0.85, fontSize / 36))
        return (0.8 + (distance - 1) * 0.45) * fontScale
    }

    private func immersiveOpacity(index: Int, isCurrent: Bool) -> Double {
        guard usesImmersiveStyle, hasTimedLyrics, !isCurrent else { return 1 }
        let distance = min(5, max(1, abs(index - max(0, currentLineIndex))))
        let nearestOpacity = index < currentLineIndex ? 0.7 : 0.88
        return max(0.18, nearestOpacity - Double(distance - 1) * 0.14)
    }

    private var lyricLineSpacing: CGFloat {
        usesImmersiveStyle ? fontSize * 0.18 : (usesSidePanelStyle ? max(6, fontSize * 0.4) : 6)
    }

    private func lyricsFont(weight: Font.Weight) -> Font {
        if let fontName {
            return .custom(fontName, size: fontSize).weight(weight)
        }
        return .system(size: fontSize, weight: weight)
    }

    private func refreshPlaybackSample() {
        sampledPlaybackTime = playbackManager.playbackProgressState.currentTime
        updateCurrentLine(for: sampledPlaybackTime)
        resetKaraokeBoundarySchedule(at: sampledPlaybackTime)
    }

    /// Determine the current lyric line based on playback time.
    /// Only executed for timed lyrics; for untimed lyrics this does nothing.
    private func updateCurrentLine(for time: TimeInterval) {
        guard hasTimedLyrics, !lyricLines.isEmpty else { return }

        let newIndex = TrackLyricsLineSelection.currentIndex(
            in: lyricLines,
            at: time,
            holdPreviousLine: usesImmersiveStyle
        )

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }

    private func resetKaraokeBoundarySchedule(at sampleTime: TimeInterval) {
        guard isKaraokeLyrics else {
            boundaryScheduler.cancel()
            return
        }
        boundaryScheduler.reset(
            sampleTime: sampleTime,
            isPlaying: playbackManager.isPlaying,
            lines: lyricLines,
            isKaraoke: true
        ) { boundaryTime in
            sampledPlaybackTime = boundaryTime
            updateCurrentLine(for: boundaryTime)
        }
    }

    private func transitionKaraokeBoundarySchedule(isPlaying: Bool) {
        guard isKaraokeLyrics else {
            boundaryScheduler.cancel()
            return
        }
        let transitionTime = boundaryScheduler.transition(
            isPlaying: isPlaying,
            lines: lyricLines,
            isKaraoke: true
        ) { boundaryTime in
            sampledPlaybackTime = boundaryTime
            updateCurrentLine(for: boundaryTime)
        }
        sampledPlaybackTime = transitionTime
        updateCurrentLine(for: transitionTime)
    }
}

private struct LyricsLanguageMenu: View {
    let availableLanguages: [LyricLanguage]
    let selectedLanguage: LyricLanguage
    @Environment(\.locale) private var locale

    var body: some View {
        Menu {
            ForEach(availableLanguages) { language in
                Toggle(isOn: Binding(
                    get: { selectedLanguage == language },
                    set: { isSelected in
                        if isSelected { LyricsScriptSettings.shared.selectLanguage(language) }
                    }
                )) {
                    languageTitle(language)
                }
            }
        } label: {
            Label(String(appLocalized: "Lyrics Language"), systemImage: "character.textbox")
        }
    }

    @ViewBuilder
    private func languageTitle(_ language: LyricLanguage) -> some View {
        if let tag = language.languageTag {
            switch tag {
            case "zh-hans": Text("Simplified Chinese")
            case "zh-hant": Text("Traditional Chinese")
            default: Text(verbatim: locale.localizedString(forIdentifier: tag) ?? tag)
            }
        } else {
            Text("Original Script")
        }
    }
}

private struct LyricsSourcePreferenceKey: PreferenceKey {
    static var defaultValue: LyricsSource? = nil

    static func reduce(value: inout LyricsSource?, nextValue: () -> LyricsSource?) {
        value = nextValue()
    }
}

/// Keep the immediate layout compensation separate from the interpolated
/// displacement. Two opposing offset modifiers can collapse to zero before
/// SwiftUI animates them; this modifier preserves the row's spring motion.
private struct ImmersiveLyricsRowMotion: AnimatableModifier {
    let displacement: CGFloat
    private var animatedDisplacement: CGFloat

    init(displacement: CGFloat) {
        self.displacement = displacement
        animatedDisplacement = displacement
    }

    var animatableData: CGFloat {
        get { animatedDisplacement }
        set { animatedDisplacement = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: displacement - animatedDisplacement)
    }
}

/// SwiftUI's ScrollViewReader can jump immediately on macOS even inside
/// withAnimation. Center the active row through the underlying clip view instead.
private struct LyricsScrollAnchor: NSViewRepresentable {
    let trackID: UUID
    let lineIndex: Int
    let animated: Bool
    var viewportAnchor: CGFloat = 0.5
    var usesRowSpring = false
    let onScroll: (_ displacement: CGFloat, _ animatesRows: Bool) -> Void

    func makeNSView(context: Context) -> LyricsScrollAnchorView {
        let view = LyricsScrollAnchorView()
        view.configure(trackID: trackID, lineIndex: lineIndex, animated: animated, viewportAnchor: viewportAnchor, usesRowSpring: usesRowSpring, onScroll: onScroll)
        return view
    }

    func updateNSView(_ view: LyricsScrollAnchorView, context: Context) {
        view.configure(trackID: trackID, lineIndex: lineIndex, animated: animated, viewportAnchor: viewportAnchor, usesRowSpring: usesRowSpring, onScroll: onScroll)
    }
}

@MainActor
private final class LyricsScrollAnchorView: NSView {
    private var target: (trackID: UUID, lineIndex: Int)?
    private var animated = false
    private var viewportAnchor: CGFloat = 0.5
    private var usesRowSpring = false
    private var onScroll: ((CGFloat, Bool) -> Void)?
    private var scrollScheduled = false
    private var hasScrolled = false
    private var lastViewportSize: NSSize?

    func configure(trackID: UUID, lineIndex: Int, animated: Bool, viewportAnchor: CGFloat, usesRowSpring: Bool, onScroll: @escaping (CGFloat, Bool) -> Void) {
        if target?.trackID != trackID || target?.lineIndex != lineIndex || self.viewportAnchor != viewportAnchor {
            target = (trackID, lineIndex)
            hasScrolled = false
        }
        self.animated = animated
        self.viewportAnchor = viewportAnchor
        self.usesRowSpring = usesRowSpring
        self.onScroll = onScroll
        scheduleScroll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleScroll()
    }

    override func layout() {
        super.layout()
        scheduleScroll()
    }

    private func scheduleScroll() {
        if hasScrolled, let scrollView = enclosingScrollView,
           scrollView.contentView.bounds.size != lastViewportSize {
            hasScrolled = false
        }
        guard !hasScrolled, !scrollScheduled, window != nil else { return }
        scrollScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scrollScheduled = false
            self?.scrollToCenter()
        }
    }

    private func scrollToCenter() {
        guard !hasScrolled, bounds.height > 0,
              let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return }

        let clipView = scrollView.contentView
        let viewportChanged = lastViewportSize != nil && lastViewportSize != clipView.bounds.size
        lastViewportSize = clipView.bounds.size
        let row = convert(bounds, to: documentView)
        let proposedOrigin = NSPoint(
            x: clipView.bounds.origin.x,
            y: row.midY - clipView.bounds.height * viewportAnchor
        )
        let origin = clipView.constrainBoundsRect(NSRect(
            origin: proposedOrigin,
            size: clipView.bounds.size
        )).origin
        hasScrolled = true

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if usesRowSpring {
            let displacement = origin.y - clipView.bounds.origin.y
            // Opening a song, resizing, or seeking far across it should place
            // the lyrics directly instead of pulling a whole viewport past.
            let animatesRows = shouldAnimate && !viewportChanged
                && abs(displacement) < clipView.bounds.height * 0.75
            onScroll?(displacement, animatesRows)
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        } else if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        if !usesRowSpring { onScroll?(0, false) }
    }
}
