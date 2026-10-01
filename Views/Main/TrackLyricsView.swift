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

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playbackManager: PlaybackManager
    @ObservedObject private var scriptSettings = LyricsScriptSettings.shared

    @State private var lyricLines: [LyricLine] = []
    @State private var lyricsSource: LyricsSource = .none
    @State private var availableScripts: [LyricScript] = [.original]
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
                    usesSidePanelStyle: usesSidePanelStyle
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

            LyricsScriptMenu(
                preference: scriptSettings.preference,
                availableScripts: availableScripts
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
            availableScripts = [.original]
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
            availableScripts = cached.availableScripts
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
        availableScripts = [.original]
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
                    availableScripts = result.availableScripts
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
                    availableScripts = [.original]
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

    @EnvironmentObject private var playbackManager: PlaybackManager
    @State private var currentLineIndex = -1
    @State private var sampledPlaybackTime: TimeInterval = 0
    @State private var lastScrolledTrackID: UUID?
    @StateObject private var boundaryScheduler = KaraokeLineBoundaryScheduler()

    // MARK: - Lyrics Content with Conditional Synced Highlight
    var body: some View {
        ScrollView {
            VStack(spacing: usesSidePanelStyle ? 6 : fontSize * 0.7) {
                ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                    lyricRow(line: line, index: index)
                        .background {
                            if hasTimedLyrics, currentLineIndex == index, let lyricsTrackID {
                                LyricsScrollAnchor(
                                    trackID: lyricsTrackID,
                                    lineIndex: index,
                                    animated: lastScrolledTrackID == lyricsTrackID
                                ) {
                                    lastScrolledTrackID = lyricsTrackID
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, usesSidePanelStyle ? 16 : 20)
            .padding(.vertical, usesSidePanelStyle ? 28 : 20)
            .frame(maxWidth: .infinity)
            .textSelection(.disabled)
        }
        .onAppear { refreshPlaybackSample() }
        .onChange(of: lyricLines) { _, _ in refreshPlaybackSample() }
        .onChange(of: lyricsTrackID) { _, _ in refreshPlaybackSample() }
        .onDisappear { boundaryScheduler.cancel() }
        .onChange(of: playbackManager.isPlaying) { _, isPlaying in
            transitionKaraokeBoundarySchedule(isPlaying: isPlaying)
        }
        // Listen for playback time changes and update the current line in real time.
        .onReceive(playbackManager.playbackProgressState.$currentTime) { newTime in
            sampledPlaybackTime = newTime
            updateCurrentLine(for: newTime)
            resetKaraokeBoundarySchedule(at: newTime)
        }
    }

    private func lyricRow(line: LyricLine, index: Int) -> some View {
        let isCurrent = hasTimedLyrics && (currentLineIndex == index ||
            (line.duetSide != nil && line.isActive(at: sampledPlaybackTime)))

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
                    lineSpacing: lyricLineSpacing
                )
                .frame(maxWidth: .infinity, alignment: line.frameAlignment)
                .scaleEffect(usesSidePanelStyle ? 1 : 1.1)
                .multilineTextAlignment(line.swiftUITextAlignment)
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .font(lyricsFont(weight: usesSidePanelStyle
                        ? (isCurrent ? .semibold : .medium)
                        : (isCurrent ? .bold : .regular)))
                    .scaleEffect(isCurrent && !usesSidePanelStyle ? 1.1 : 1.0)
                    .foregroundColor(isCurrent || (usesSidePanelStyle && !hasTimedLyrics)
                        ? activeColor : inactiveColor)
                    .multilineTextAlignment(line.swiftUITextAlignment)
                    .lineSpacing(lyricLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: line.frameAlignment)
            }
        }
        .padding(.horizontal, usesSidePanelStyle ? 12 : 0)
        .padding(.vertical, usesSidePanelStyle ? 10 : 0)
    }

    private var lyricLineSpacing: CGFloat {
        usesSidePanelStyle ? max(6, fontSize * 0.4) : 6
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

        // Prefer precise judgment via endTime; fall back to startTime ≤ time when endTime is nil
        let newIndex = lyricLines.lastIndex { line in
            if let end = line.endTime {
                return time >= line.startTime && time < end
            } else {
                return line.startTime <= time
            }
        } ?? -1

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

private struct LyricsScriptMenu: View {
    let preference: LyricsScriptPreference
    let availableScripts: [LyricScript]

    var body: some View {
        Menu {
            ForEach(LyricsScriptPreference.allCases) { option in
                Toggle(isOn: Binding(
                    get: { preference == option },
                    set: { isSelected in
                        if isSelected { LyricsScriptSettings.shared.select(option) }
                    }
                )) {
                    Text(option.title)
                }
                .disabled(!isSelectable(option))
            }
        } label: {
            Label(String(appLocalized: "Lyrics Script"), systemImage: "character.textbox")
        }
    }

    /// Follow/original remain available because the parser falls back to the
    /// body script when a line does not carry the requested variant.
    private func isSelectable(_ option: LyricsScriptPreference) -> Bool {
        switch option {
        case .followAppLanguage, .original: true
        case .simplified: availableScripts.contains(.simplified)
        case .traditional: availableScripts.contains(.traditional)
        }
    }
}

private struct LyricsSourcePreferenceKey: PreferenceKey {
    static var defaultValue: LyricsSource? = nil

    static func reduce(value: inout LyricsSource?, nextValue: () -> LyricsSource?) {
        value = nextValue()
    }
}

/// SwiftUI's ScrollViewReader can jump immediately on macOS even inside
/// withAnimation. Center the active row through the underlying clip view instead.
private struct LyricsScrollAnchor: NSViewRepresentable {
    let trackID: UUID
    let lineIndex: Int
    let animated: Bool
    let onScroll: () -> Void

    func makeNSView(context: Context) -> LyricsScrollAnchorView {
        let view = LyricsScrollAnchorView()
        view.configure(trackID: trackID, lineIndex: lineIndex, animated: animated, onScroll: onScroll)
        return view
    }

    func updateNSView(_ view: LyricsScrollAnchorView, context: Context) {
        view.configure(trackID: trackID, lineIndex: lineIndex, animated: animated, onScroll: onScroll)
    }
}

private final class LyricsScrollAnchorView: NSView {
    private var target: (trackID: UUID, lineIndex: Int)?
    private var animated = false
    private var onScroll: (() -> Void)?
    private var scrollScheduled = false
    private var hasScrolled = false

    func configure(trackID: UUID, lineIndex: Int, animated: Bool, onScroll: @escaping () -> Void) {
        if target?.trackID != trackID || target?.lineIndex != lineIndex {
            target = (trackID, lineIndex)
            hasScrolled = false
        }
        self.animated = animated
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
        let row = convert(bounds, to: documentView)
        let proposedOrigin = NSPoint(
            x: clipView.bounds.origin.x,
            y: row.midY - clipView.bounds.height / 2
        )
        let origin = clipView.constrainBoundsRect(NSRect(
            origin: proposedOrigin,
            size: clipView.bounds.size
        )).origin
        hasScrolled = true

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        onScroll?()
    }
}
