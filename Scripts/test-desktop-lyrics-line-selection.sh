#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual: \(actual)\n", stderr)
        exit(1)
    }
}

func assertNil<T>(_ actual: T?, _ message: String) {
    if actual != nil {
        fputs("FAIL: \(message)\nexpected nil, actual: \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

let timed = [
    LyricLine(text: "first", startTime: 0, endTime: 10),
    LyricLine(text: "", startTime: 10, endTime: 12),
    LyricLine(text: "second", startTime: 12, endTime: 20),
    LyricLine(text: "third", startTime: 20, endTime: nil)
]

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 4),
    DesktopLyricsDisplayLines(current: timed[0], next: timed[2]),
    "synced lyrics select current line and next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 11),
    DesktopLyricsDisplayLines(current: timed[2], next: timed[3]),
    "empty active lines advance to the next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: -1),
    DesktopLyricsDisplayLines(current: timed[0], next: timed[2]),
    "times before the first timestamp show the first two non-empty lines"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 22),
    DesktopLyricsDisplayLines(current: timed[3], next: nil),
    "last synced line has no next line"
)

let emptyTail = [
    LyricLine(text: "first", startTime: 0, endTime: 10),
    LyricLine(text: "", startTime: 10, endTime: nil)
]

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: emptyTail, at: 12),
    "empty active tail line does not wrap to earlier lyrics"
)

let finiteTimed = [
    LyricLine(text: "first", startTime: 0, endTime: 1),
    LyricLine(text: "second", startTime: 5, endTime: 6)
]

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: finiteTimed, at: 3),
    "finite-ended timed lyrics return nil during gaps"
)

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: finiteTimed, at: 7),
    "finite-ended timed lyrics return nil after the final line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(
        lines: finiteTimed,
        at: 3,
        gapBehavior: .holdPreviousLine
    ),
    DesktopLyricsDisplayLines(current: finiteTimed[0], next: finiteTimed[1]),
    "KSC gaps hold the most recently started non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(
        lines: finiteTimed,
        at: 7,
        gapBehavior: .holdPreviousLine
    ),
    DesktopLyricsDisplayLines(current: finiteTimed[1], next: nil),
    "KSC keeps the final non-empty line after its end time"
)

let plain = [
    LyricLine(text: "", startTime: 0),
    LyricLine(text: "plain one", startTime: 0),
    LyricLine(text: "plain two", startTime: 0)
]

assertEqual(
    DesktopLyricsLineSelection.plainDisplayLines(lines: plain),
    DesktopLyricsDisplayLines(current: plain[1], next: plain[2]),
    "plain lyrics use first two non-empty lines"
)

assertNil(
    DesktopLyricsLineSelection.plainDisplayLines(lines: [LyricLine(text: "   ", startTime: 0)]),
    "blank lyrics do not produce display lines"
)

print("Desktop lyrics line selection tests passed")
SWIFT

swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/DesktopLyricsLineSelection.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/DesktopLyricsLineSelectionTests"

"$TMP_DIR/DesktopLyricsLineSelectionTests"

cat > "$TMP_DIR/DesktopLyricsProviderIntegration.swift" <<'SWIFT'
import Combine
import Foundation

struct Track {
    let id: UUID
}

final class PlaybackProgressState {
    var currentTime: TimeInterval

    init(currentTime: TimeInterval) {
        self.currentTime = currentTime
    }
}

@MainActor
final class PlaybackManager {
    var currentTrack: Track?
    let playbackProgressState: PlaybackProgressState
    var isPlaying: Bool
    private(set) var fineSamplingConsumers = 0

    init(currentTrack: Track?, currentTime: TimeInterval, isPlaying: Bool) {
        self.currentTrack = currentTrack
        playbackProgressState = PlaybackProgressState(currentTime: currentTime)
        self.isPlaying = isPlaying
    }

    func setFineProgressSampling(_ enabled: Bool) {
        fineSamplingConsumers += enabled ? 1 : -1
    }
}

struct StubDatabaseQueue {}

final class StubDatabaseManager {
    let dbQueue = StubDatabaseQueue()
}

final class LibraryManager {
    let databaseManager = StubDatabaseManager()
}

@MainActor
final class LyricsStore {
    static let shared = LyricsStore()

    struct Lyrics {
        let trackId: UUID
        let lines: [LyricLine]
        let hasTimed: Bool
        let isKaraoke: Bool
    }

    var cached: Lyrics?

    func cachedLyrics(for trackId: UUID) -> Lyrics? {
        guard cached?.trackId == trackId else { return nil }
        return cached
    }

    func lyrics(
        for track: Track,
        using dbQueue: StubDatabaseQueue
    ) async throws -> Lyrics {
        guard let cached, cached.trackId == track.id else {
            fatalError("Missing provider integration fixture")
        }
        return cached
    }
}

@main
struct DesktopLyricsProviderIntegrationTests {
    @MainActor
    static func main() async {
        let first = LyricLine(
            text: "first",
            startTime: 0.05,
            endTime: 0.15,
            timingSegments: [
                LyricTimingSegment(text: "first", startOffset: 0, duration: 0.10),
            ]
        )
        let second = LyricLine(
            text: "second",
            startTime: 0.15,
            endTime: 0.35,
            timingSegments: [
                LyricTimingSegment(text: "second", startOffset: 0, duration: 0.20),
            ]
        )
        let track = Track(id: UUID())
        LyricsStore.shared.cached = LyricsStore.Lyrics(
            trackId: track.id,
            lines: [first, second],
            hasTimed: true,
            isKaraoke: true
        )

        let playbackManager = PlaybackManager(currentTrack: track, currentTime: 0, isPlaying: true)
        let libraryManager = LibraryManager()
        let provider = DesktopLyricsLineProvider(
            playbackManager: playbackManager,
            libraryManager: libraryManager
        )
        var publishedPairs: [(LyricLine, TimeInterval)] = []
        let stateObservation = provider.$state.sink { [weak provider] state in
            guard case .lyrics(let display) = state, let provider else { return }
            publishedPairs.append((display.current, provider.rendererSampleTime))
        }

        provider.appear()
        assertCurrent(provider, equals: first, message: "Load initialization must select the first KSC line")
        assertClose(provider.rendererSampleTime, 0,
                    "Load initialization must publish the renderer's sample")

        try? await Task.sleep(nanoseconds: 220_000_000)
        assertCurrent(provider, equals: second,
                      message: "The local 0.15s boundary must select the second short KSC line")
        assertClose(provider.rendererSampleTime, 0.15,
                    "The local boundary must advance selection and renderer sample together")
        guard let secondPublication = publishedPairs.last(where: { $0.0 == second }) else {
            preconditionFailure("The second KSC line was never published")
        }
        assertClose(secondPublication.1, 0.15,
                    "Renderer sample must update before the selected-line publication")

        provider.playbackTimeChanged(0.08)
        assertCurrent(provider, equals: first, message: "A global sample/seek must immediately reselect")
        assertClose(provider.rendererSampleTime, 0.08,
                    "A global sample/seek must immediately replace the renderer sample")

        playbackManager.isPlaying = false
        provider.playbackStateChanged(isPlaying: false)
        let pausedTime = provider.rendererSampleTime
        precondition(pausedTime >= 0.08 && pausedTime < 0.15,
                     "Pause must publish the interpolated transition time, got \(pausedTime)")
        assertCurrent(provider, equals: first,
                      message: "Pause transition time and selected line must stay synchronized")
        try? await Task.sleep(nanoseconds: 100_000_000)
        assertClose(provider.rendererSampleTime, pausedTime,
                    "Paused desktop renderer sample must remain frozen")

        playbackManager.isPlaying = true
        provider.playbackStateChanged(isPlaying: true)
        try? await Task.sleep(nanoseconds: 120_000_000)
        assertCurrent(provider, equals: second,
                      message: "Resume must schedule the next short KSC boundary")
        assertClose(provider.rendererSampleTime, 0.15,
                    "Resume boundary must advance the renderer sample with selection")

        provider.disappear()
        withExtendedLifetime(stateObservation) {}
        precondition(playbackManager.fineSamplingConsumers == 0,
                     "Provider lifecycle must release fine progress sampling")

        let gapFirst = LyricLine(
            text: "gap first",
            startTime: 0,
            endTime: 1,
            timingSegments: [
                LyricTimingSegment(text: "gap first", startOffset: 0, duration: 1),
            ]
        )
        let gapSecond = LyricLine(
            text: "gap second",
            startTime: 5,
            endTime: 6,
            timingSegments: [
                LyricTimingSegment(text: "gap second", startOffset: 0, duration: 1),
            ]
        )
        let gapTrack = Track(id: UUID())
        LyricsStore.shared.cached = LyricsStore.Lyrics(
            trackId: gapTrack.id,
            lines: [gapFirst, gapSecond],
            hasTimed: true,
            isKaraoke: true
        )
        let gapPlaybackManager = PlaybackManager(
            currentTrack: gapTrack,
            currentTime: 3,
            isPlaying: false
        )
        let gapProvider = DesktopLyricsLineProvider(
            playbackManager: gapPlaybackManager,
            libraryManager: libraryManager
        )

        gapProvider.appear()
        assertCurrent(
            gapProvider,
            equals: gapFirst,
            message: "A loaded KSC gap must keep the completed previous line"
        )
        gapProvider.playbackTimeChanged(7)
        assertCurrent(
            gapProvider,
            equals: gapSecond,
            message: "KSC must keep the final line after its end time"
        )
        gapProvider.disappear()
        precondition(gapPlaybackManager.fineSamplingConsumers == 0,
                     "Gap provider lifecycle must release fine progress sampling")
        print("Desktop lyrics provider boundary/sample integration tests passed")
    }

    @MainActor
    private static func assertCurrent(
        _ provider: DesktopLyricsLineProvider,
        equals expected: LyricLine,
        message: String
    ) {
        guard case .lyrics(let display) = provider.state, display.current == expected else {
            preconditionFailure("\(message): got \(provider.state)")
        }
    }

    private static func assertClose(_ actual: Double, _ expected: Double, _ message: String) {
        precondition(abs(actual - expected) < 0.005,
                     "\(message): expected \(expected), got \(actual)")
    }
}
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/DesktopLyricsLineSelection.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$ROOT_DIR/Views/DesktopLyrics/DesktopLyricsLineProvider.swift" \
    "$TMP_DIR/DesktopLyricsProviderIntegration.swift" \
    -o "$TMP_DIR/DesktopLyricsProviderIntegrationTests"

"$TMP_DIR/DesktopLyricsProviderIntegrationTests"

desktop_view="$ROOT_DIR/Views/DesktopLyrics/DesktopLyricsView.swift"
rg -n 'sampleTime: provider\.rendererSampleTime' "$desktop_view" >/dev/null || {
    printf 'Desktop KaraokeLyricText must consume the provider scheduler sample.\n' >&2
    exit 1
}
if rg -n '@State private var sampledPlaybackTime' "$desktop_view" >/dev/null; then
    printf 'DesktopLyricsView must not keep a second global-only renderer sample.\n' >&2
    exit 1
fi
