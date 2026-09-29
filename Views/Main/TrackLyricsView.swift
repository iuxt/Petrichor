import AppKit
import SwiftUI

struct TrackLyricsView: View {
    let onClose: () -> Void
    @EnvironmentObject private var playbackManager: PlaybackManager
    @State private var searchRequest: LyricsSearchRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TrackLyricsContent()
        }
        .sheet(item: $searchRequest) { LyricsSearchSheet(track: $0.track) }
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

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playbackManager: PlaybackManager

    @State private var lyricLines: [LyricLine] = []
    @State private var lyricsSource: LyricsSource = .none
    @State private var lyricsTrackID: UUID?
    @State private var isLoading = true
    @State private var fetchFailed = false
    @State private var loadGeneration = UUID()
    @State private var searchRequest: LyricsSearchRequest?
    @State private var deletionRequest: LyricsDeletionRequest?
    @State private var currentLineIndex: Int = -1
    @State private var hasTimedLyrics: Bool = false
    @State private var isKaraokeLyrics = false
    @State private var sampledPlaybackTime: TimeInterval = 0
    @StateObject private var boundaryScheduler = KaraokeLineBoundaryScheduler()

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
                lyricsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onDisappear {
            boundaryScheduler.cancel()
            playbackManager.setFineProgressSampling(false)
        }
        .onChange(of: playbackManager.currentTrack?.id) { _, _ in
            boundaryScheduler.cancel()
            loadLyricsForCurrentTrack()
        }
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

    // MARK: - Lyrics Content with Conditional Synced Highlight
    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: fontSize * 0.7) {
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                        lyricRow(line: line, index: index)
                            .id(index)   // For scrollTo
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .onChange(of: currentLineIndex) { _, newIndex in
                // Auto-scroll only for timed lyrics
                guard hasTimedLyrics else { return }
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func lyricRow(line: LyricLine, index: Int) -> some View {
        let isCurrent = hasTimedLyrics && currentLineIndex == index

        if isCurrent, line.timingSegments?.isEmpty == false {
            KaraokeLyricText(
                line: line,
                sampleTime: sampledPlaybackTime,
                isPlaying: playbackManager.isPlaying,
                fontName: fontName,
                fontSize: fontSize,
                fontWeight: .bold,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                lineSpacing: 6
            )
            .frame(maxWidth: .infinity)
            .scaleEffect(1.1)
            .multilineTextAlignment(.center)
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .font(lyricsFont(weight: isCurrent ? .bold : .regular))
                .scaleEffect(isCurrent ? 1.1 : 1.0)
                .foregroundColor(isCurrent ? activeColor : inactiveColor)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
        }
    }

    private func lyricsFont(weight: Font.Weight) -> Font {
        if let fontName {
            return .custom(fontName, size: fontSize).weight(weight)
        }
        return .system(size: fontSize, weight: weight)
    }

    // MARK: - Helper Methods

    private func loadLyricsForCurrentTrack(forceReload: Bool = false) {
        let generation = UUID()
        loadGeneration = generation
        guard let track = currentTrack else {
            boundaryScheduler.cancel()
            lyricLines = []
            lyricsSource = .none
            lyricsTrackID = nil
            hasTimedLyrics = false
            isKaraokeLyrics = false
            isLoading = false
            fetchFailed = false
            return
        }

        currentLineIndex = -1
        let loadedTrackId = track.id

        if !forceReload, let cached = LyricsStore.shared.cachedLyrics(for: loadedTrackId) {
            lyricLines = cached.lines
            lyricsSource = cached.source
            lyricsTrackID = loadedTrackId
            hasTimedLyrics = cached.hasTimed
            isKaraokeLyrics = cached.isKaraoke
            isLoading = false
            fetchFailed = false
            sampledPlaybackTime = playbackManager.playbackProgressState.currentTime
            updateCurrentLine(for: sampledPlaybackTime)
            resetKaraokeBoundarySchedule(at: sampledPlaybackTime)
            return
        }

        boundaryScheduler.cancel()
        isLoading = true
        lyricLines = []
        lyricsSource = .none
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
                    lyricsTrackID = loadedTrackId
                    hasTimedLyrics = result.hasTimed
                    isKaraokeLyrics = result.isKaraoke
                    isLoading = false
                    fetchFailed = false
                    sampledPlaybackTime = playbackManager.playbackProgressState.currentTime
                    updateCurrentLine(for: sampledPlaybackTime)
                    resetKaraokeBoundarySchedule(at: sampledPlaybackTime)
                }
            } catch {
                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId, loadGeneration == generation else { return }
                    boundaryScheduler.cancel()
                    lyricLines = []
                    lyricsSource = .none
                    lyricsTrackID = nil
                    hasTimedLyrics = false
                    isKaraokeLyrics = false
                    isLoading = false
                    fetchFailed = true
                }
            }
        }
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
