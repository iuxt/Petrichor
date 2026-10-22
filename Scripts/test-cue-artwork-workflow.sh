#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-cue-artwork.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation
import Combine
extension String { init(appLocalized key: String) { self = key } }
enum OnlineTagProvider: String, Sendable { case netease, qqMusic }
struct OnlineTagCandidate: Identifiable, Equatable, Sendable {
    let songID: String; let title: String; let artist: String; let album: String
    var id: String { songID }
}
protocol OnlineTagSearching: Sendable { func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] }
struct OnlineTagLookupService: OnlineTagSearching { func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] { [] } }
protocol OnlineArtworkServing: Sendable { func download(for candidate: OnlineTagCandidate) async throws -> Data }
struct OnlineArtworkService: OnlineArtworkServing { func download(for candidate: OnlineTagCandidate) async throws -> Data { Data() } }
enum ArtworkDownloadError: Error { case invalidResponse, unavailable, unsafeDestination, existingArtwork }
// Matching itself is covered by the lyrics/tag matching suite; this harness tests
// production transport, album deduplication, real sidecar writes and UI save flow.
struct LyricsMatchQuery {
    let title: String; let artist: String; let album: String; let duration: Double
    var isComplete: Bool { !title.isEmpty }
    func automaticMatch(in candidates: [OnlineTagCandidate], requireAlbum: Bool = false) -> OnlineTagCandidate? { candidates.first }
}
@MainActor final class LyricsDownloadSettings: ObservableObject {
    static let shared = LyricsDownloadSettings()
    @Published var automaticallyDownloadArtwork = false
    @Published var artworkSource: OnlineTagProvider = .netease
}
struct Track {
    let url: URL; let title: String; let cueSegment: CueTrackSegment?
    var artist = "Artist"; var album = "Album"; var albumArtist: String? = "Artist"
    var duration = 120.0; var albumId: Int64? = 1
    var artworkSourceURL: URL { cueSegment?.albumSourceURL ?? url }
}
@MainActor final class PlaybackManager: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    var refreshed: [URL] = []
    func refreshCurrentTrackArtworkAfterDownload(for url: URL) { refreshed.append(url) }
}
@MainActor final class AppCoordinator {
    static let shared: AppCoordinator? = AppCoordinator()
    let playbackManager = PlaybackManager()
}
@MainActor final class NotificationManager {
    static let shared = NotificationManager()
    enum Kind { case info, error }
    func addMessage(_ kind: Kind, _ text: String) {}
}
actor TrackThumbnailCache { static let shared = TrackThumbnailCache(); func removeAll() {} }
final class ArtworkResolver {
    static let shared = ArtworkResolver()
    func artworkData(for request: ArtworkRequest) async -> Data? {
        guard let cue = request.cueSheetURL else { return nil }
        return try? Data(contentsOf: cue.appendingPathExtension("jpg"))
    }
    func invalidateMemoryCache() {}
}
enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png"]
    static let knownFilenames = ["cover", "folder", "album"]
    static let maxArtworkSize = 20 * 1024 * 1024
    static func isSupported(_ ext: String) -> Bool { supportedExtensions.contains(ext.lowercased()) }
}
enum FilesystemUtils { static func sanitizeFilename(_ value: String) -> String { value.replacingOccurrences(of: "/", with: "_") } }
actor Search: OnlineTagSearching {
    var count = 0
    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] {
        count += 1
        return [OnlineTagCandidate(songID: "1", title: title, artist: artist, album: "Album")]
    }
}
actor Images: OnlineArtworkServing {
    var count = 0
    var suspended = true
    var continuation: CheckedContinuation<Void, Never>?
    var image = Data("cover".utf8)
    func download(for candidate: OnlineTagCandidate) async throws -> Data {
        count += 1
        if suspended { await withCheckedContinuation { continuation = $0 } }
        return image
    }
    func resume() { suspended = false; continuation?.resume(); continuation = nil }
    func replace() { image = Data("replacement".utf8) }
}
@main struct Harness {
    @MainActor static func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    @MainActor static func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            pump()
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Workflow timed out")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let sub = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let cue = root.appendingPathComponent("Album.cue")
        let a = sub.appendingPathComponent("a.flac"), b = sub.appendingPathComponent("b.flac")
        try Data("cue".utf8).write(to: cue)
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let first = Track(url: a, title: "First", cueSegment: CueTrackSegment(sheetPath: cue.path, sourcePath: a.path, number: 1, start: 0, end: 120, albumSourcePath: a.path))
        let second = Track(url: b, title: "Second", cueSegment: CueTrackSegment(sheetPath: cue.path, sourcePath: b.path, number: 2, start: 0, end: 120, albumSourcePath: a.path))
        let settings = LyricsDownloadSettings(), search = Search(), images = Images()
        let playback = AppCoordinator.shared!.playbackManager
        let automatic = AutomaticArtworkDownloader(settings: settings, search: search, service: images)
        automatic.connect(playbackManager: playback)
        playback.currentTrack = first; playback.isPlaying = true
        pump()
        precondition(await search.count == 0, "Artwork opt-in stays off by default")
        settings.automaticallyDownloadArtwork = true
        await wait { await images.count == 1 }
        playback.currentTrack = second
        pump()
        await images.resume()
        let cover = cue.appendingPathExtension("jpg")
        await wait { FileManager.default.fileExists(atPath: cover.path) && !playback.refreshed.isEmpty }
        precondition(await search.count == 1, "Advancing within a multi-file CUE must not restart the pending album request")
        precondition(playback.refreshed.last == cue, "Notify the whole album even after the current audio file changes")
        await images.replace()
        let manual = ArtworkSearchViewModel(track: second, settings: settings, searchService: search, artworkService: images)
        manual.checkLocalArtwork()
        await wait { !manual.isCheckingArtwork }
        precondition(manual.hasExistingArtwork)
        manual.search(); await wait { !manual.isSearching }
        manual.selection = manual.candidates.first!.id
        await wait { manual.previewData != nil }
        manual.save()
        precondition(manual.needsOverwriteConfirmation)
        manual.save(overwrite: true)
        await wait { manual.savedURL != nil }
        precondition(manual.savedURL == cover && Data(contentsOf: cover) == Data("replacement".utf8))
        precondition(try Data(contentsOf: a) == Data("a".utf8) && Data(contentsOf: b) == Data("b".utf8) && Data(contentsOf: cue) == Data("cue".utf8))
        precondition(!FileManager.default.fileExists(atPath: b.deletingPathExtension().appendingPathExtension("jpg").path))
        print("CUE artwork workflows: opt-in, in-flight album deduplication, multi-file notifications and manual replacement passed")
    }
}
SWIFT
python3 - "$TMP_DIR/Harness.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text().replace('        precondition(await search.count == 0,', '        let before = await search.count\n        precondition(before == 0,').replace('        precondition(await search.count == 1,', '        let after = await search.count\n        precondition(after == 1,')
s=s.replace('        precondition(manual.savedURL == cover && Data(contentsOf: cover) == Data("replacement".utf8))', '        let saved = try Data(contentsOf: cover)\n        precondition(manual.savedURL == cover && saved == Data("replacement".utf8))').replace('        precondition(try Data(contentsOf: a) == Data("a".utf8) && Data(contentsOf: b) == Data("b".utf8) && Data(contentsOf: cue) == Data("cue".utf8))','        let aBytes = try Data(contentsOf: a), bBytes = try Data(contentsOf: b), cueBytes = try Data(contentsOf: cue)\n        precondition(aBytes == Data("a".utf8) && bBytes == Data("b".utf8) && cueBytes == Data("cue".utf8))');p.write_text(s)
PY
xcrun swiftc "$ROOT_DIR/Core/Cue/CueSheet.swift" "$ROOT_DIR/Core/Artwork/ArtworkRequest.swift" \
    "$ROOT_DIR/Core/Metadata/ExternalArtworkResolver.swift" "$ROOT_DIR/Core/Artwork/DownloadedArtworkFileStore.swift" \
    "$ROOT_DIR/Managers/AutomaticArtworkDownloader.swift" "$ROOT_DIR/Managers/ArtworkSearchViewModel.swift" \
    "$TMP_DIR/Harness.swift" -o "$TMP_DIR/cue-artwork-test"
"$TMP_DIR/cue-artwork-test" "$TMP_DIR/library"
