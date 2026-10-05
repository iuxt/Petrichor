#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-lyrics-cache.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/GRDB.swift" <<'SWIFT'
public final class DatabaseQueue: @unchecked Sendable { public init() {} }
SWIFT
xcrun swiftc -emit-module -emit-library -module-name GRDB "$TMP_DIR/GRDB.swift" -o "$TMP_DIR/libGRDB.dylib"
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation
import GRDB
struct Track: Sendable { let id: UUID; let url: URL }
struct LyricLine: Sendable { let text: String; let startTime: Double; let endTime: Double?; let timingSegments: [Int]? }
enum LyricsSource {
    case lrc, ksc
    func sidecarURL(for audioURL: URL) -> URL? {
        audioURL.deletingPathExtension().appendingPathExtension(self == .lrc ? "lrc" : "ksc")
    }
}
enum LyricScript: String, CaseIterable, Sendable { case original, simplified, traditional }
struct LyricLanguage: Equatable, Sendable {
    let languageTag: String?
    static let original = Self(languageTag: nil)
}
extension Notification.Name {
    static let lyricsScriptPreferenceDidChange = Notification.Name("lyricsScriptPreferenceDidChange")
    static let downloadedLyricsDidChange = Notification.Name("DownloadedLyricsDidChange")
}
@MainActor final class LyricsScriptSettings {
    static let shared = LyricsScriptSettings()
    var effectiveScript: LyricScript { .original }
    var languageTag: String? { nil }
}
actor ControlledLoader {
    var count = 0
    var waiters: [Int: CheckedContinuation<String, Never>] = [:]
    private var requestedScripts: [LyricScript] = []
    private var requestedLanguages: [String?] = []
    func load(script: LyricScript, languageTag: String?) async -> String {
        count += 1
        requestedScripts.append(script)
        requestedLanguages.append(languageTag)
        let id = count
        return await withCheckedContinuation { waiters[id] = $0 }
    }
    func scriptRequested(at load: Int) -> LyricScript? { load <= requestedScripts.count ? requestedScripts[load - 1] : nil }
    func languageRequested(at load: Int) -> String? { requestedLanguages[load - 1] }
    func complete(_ id: Int, _ value: String) { waiters.removeValue(forKey: id)?.resume(returning: value) }
}
enum LyricsLoader {
    static let controlled = ControlledLoader()
    static func loadLyrics(for track: Track, using db: DatabaseQueue, script: LyricScript = .original, languageTag: String? = nil) async throws
        -> (lyrics: [LyricLine], source: LyricsSource, availableScripts: [LyricScript], availableLanguages: [LyricLanguage], selectedLanguage: LyricLanguage) {
        let text = await controlled.load(script: script, languageTag: languageTag)
        return ([LyricLine(text: text, startTime: 1, endTime: nil, timingSegments: text == "downloaded" ? [1] : nil)], .lrc,
                [.original, .simplified], [LyricLanguage(languageTag: "zh-hant"), LyricLanguage(languageTag: "zh-hans")], LyricLanguage(languageTag: languageTag))
    }
}
func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
@main struct Harness {
    @MainActor static func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out")
    }
    @MainActor static func main() async throws {
        let track = Track(id: UUID(), url: URL(fileURLWithPath: "/tmp/test-song.flac"))
        let db = DatabaseQueue()
        let store = LyricsStore.shared
        let original = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 1 }
        let joining = Task { try await store.lyrics(for: track, using: db) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(await LyricsLoader.controlled.count == 1, "Concurrent views must share one read")
        store.invalidate(for: track.url)
        let updated = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 2 }
        await LyricsLoader.controlled.complete(2, "downloaded")
        let fresh = try await updated.value
        expect(fresh.lines[0].text == "downloaded", "Reload must show downloaded data")
        expect(fresh.isKaraoke, "Timed enhanced LRC must enable karaoke playback")
        await LyricsLoader.controlled.complete(1, "stale")
        for task in [original, joining] {
            do { _ = try await task.value; fatalError("Stale reader must be rejected") }
            catch is CancellationError {} catch { throw error }
        }
        expect(store.cachedLyrics(for: track.id)?.lines[0].text == "downloaded", "Old completion must not overwrite the cache")
        store.invalidate(for: URL(fileURLWithPath: "/tmp/other.flac"))
        expect(store.cachedLyrics(for: track.id) != nil, "Unrelated downloads must not invalidate current lyrics")
        store.invalidate(for: track.url)
        expect(store.cachedLyrics(for: track.id) == nil, "Downloaded track must invalidate cached lyrics")

        // --- Script preference: the resolved script reaches the loader and results ---
        store.scriptResolver = { .simplified }
        let simplifiedLoad = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 3 }
        expect(await LyricsLoader.controlled.scriptRequested(at: 3) == .simplified,
               "The store must pass the resolved script to the loader")
        await LyricsLoader.controlled.complete(3, "simplified-text")
        let simplifiedResult = try await simplifiedLoad.value
        expect(simplifiedResult.lines[0].text == "simplified-text", "Simplified load must return its lines")
        expect(simplifiedResult.availableScripts == [.original, .simplified],
               "Availability must flow into the cached Lyrics value")

        // --- A preference change notification invalidates the cache and re-resolves ---
        expect(store.cachedLyrics(for: track.id)?.lines.first?.text == "simplified-text",
               "Sanity: the simplified parse is cached before the switch")
        store.scriptResolver = { .original }
        expect(store.cachedLyrics(for: track.id) == nil, "Changed selection must reject the cache before notifications arrive")
        NotificationCenter.default.post(name: .lyricsScriptPreferenceDidChange, object: nil)
        let reloaded = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 4 }
        expect(await LyricsLoader.controlled.scriptRequested(at: 4) == .original,
               "After the notification the cache must miss and re-resolve the script")
        await LyricsLoader.controlled.complete(4, "original-text")
        expect(try await reloaded.value.lines[0].text == "original-text",
               "The post-switch load must show the original script text")
        // Language changes reject cached and pending data independently of observer order.
        store.languageResolver = { "zh-hant" }
        expect(store.cachedLyrics(for: track.id) == nil, "Changing language must reject the previous cache")
        let traditionalLoad = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 5 }
        expect(await LyricsLoader.controlled.languageRequested(at: 5) == "zh-hant", "Language reaches loader")
        store.languageResolver = { "zh-hans" }
        let simplifiedLanguageLoad = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 6 }
        await LyricsLoader.controlled.complete(6, "new-language")
        let selected = try await simplifiedLanguageLoad.value
        expect(selected.selectedLanguage.languageTag == "zh-hans", "Cache reports the rendered language")
        expect(selected.availableLanguages.count == 2, "File languages reach the menu")
        await LyricsLoader.controlled.complete(5, "old-language")
        do { _ = try await traditionalLoad.value; fatalError("Previous-language loads must be cancelled") }
        catch is CancellationError {} catch { throw error }
        expect(store.cachedLyrics(for: track.id)?.lines.first?.text == "new-language", "Old language must not overwrite selection")
        store.invalidateAll()
        let pending = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 7 }
        let pendingJoin = Task { try await store.lyrics(for: track, using: db) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        store.languageResolver = { "ja" }
        await LyricsLoader.controlled.complete(7, "obsolete-language")
        for task in [pending, pendingJoin] {
            do { _ = try await task.value; fatalError("Every reader must reject an obsolete selection") }
            catch is CancellationError {} catch { throw error }
        }
        expect(store.cachedLyrics(for: track.id) == nil, "Obsolete selection must not enter the cache")

        // Manual reload invalidates before notifying all four surfaces, which
        // must share one fresh read even if an older read is still pending.
        let oldLoad = Task { try await store.lyrics(for: track, using: db) }
        await wait { await LyricsLoader.controlled.count == 8 }
        var readers: [Task<LyricsStore.Lyrics, Error>] = []
        let observers = (0..<4).map { _ in
            NotificationCenter.default.addObserver(
                forName: .downloadedLyricsDidChange, object: nil, queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    guard let url = notification.object as? URL,
                          url.standardizedFileURL == track.url.standardizedFileURL else { return }
                    expect(store.cachedLyrics(for: track.id) == nil,
                           "Every surface must see the cache invalidated before reloading")
                    readers.append(Task { try await store.lyrics(for: track, using: db) })
                }
            }
        }
        store.reload(for: URL(fileURLWithPath: "/tmp/unrelated.flac"))
        expect(readers.isEmpty, "Reloading another track must not refresh current surfaces")
        store.reload(for: track.url)
        expect(readers.count == 4, "Manual reload must notify all four surfaces")
        await wait { await LyricsLoader.controlled.count == 9 }
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(await LyricsLoader.controlled.count == 9, "Four surfaces must share one fresh read")
        await LyricsLoader.controlled.complete(9, "manually-reloaded")
        for reader in readers {
            expect(try await reader.value.lines[0].text == "manually-reloaded",
                   "Every surface must receive the new lyrics")
        }
        await LyricsLoader.controlled.complete(8, "before-reload")
        do { _ = try await oldLoad.value; fatalError("Manual reload must reject pending old lyrics") }
        catch is CancellationError {} catch { throw error }
        expect(store.cachedLyrics(for: track.id)?.lines[0].text == "manually-reloaded",
               "An old read must not replace manually reloaded lyrics")
        readers.removeAll()
        store.reload(for: track.url)
        expect(readers.count == 4, "Reload must also notify surfaces with cached lyrics")
        await wait { await LyricsLoader.controlled.count == 10 }
        await LyricsLoader.controlled.complete(10, "edited-sidecar")
        for reader in readers {
            expect(try await reader.value.lines[0].text == "edited-sidecar",
                   "Reload must replace cached lyrics on every surface")
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        print("Lyrics cache invalidation and stale-load checks passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library -I "$TMP_DIR" -L "$TMP_DIR" -lGRDB -Xlinker -rpath -Xlinker "$TMP_DIR" \
    "$ROOT_DIR/Core/LyricsStore.swift" "$TMP_DIR/Harness.swift" -o "$TMP_DIR/test-cache"
"$TMP_DIR/test-cache"
