#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-lyrics-download.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/Stubs.swift" <<'SWIFT'
import Foundation
import Combine
extension String { init(appLocalized key: String) { self = key } }
struct Track: Sendable {
    var url: URL
    var title = "Song"
    var artist = "Artist"
    var album = "Album"
    var duration = 120.0
}
@MainActor final class LyricsStore {
    static let shared = LyricsStore()
    func invalidate(for url: URL) {}
}
@MainActor final class PlaybackManager {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
}
SWIFT
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
final class MockLyricsURLProtocol: URLProtocol {
    static var reply: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let candidate = OnlineTagCandidate(provider: .netease, songID: "1", title: "Song", artist: "Artist", album: "Album", duration: 120, trackNumber: nil)
let qqCandidate = OnlineTagCandidate(provider: .qqMusic, songID: "qq1", title: "Song", artist: "Artist", album: "Album", duration: 120, trackNumber: nil)
let content = DownloadedLyrics(lrc: "[00:01.000]First\n[00:02.000]Second\n")
actor FakeService: OnlineLyricsServing {
    private(set) var searches = 0
    private(set) var ttmlSearches = 0
    private(set) var downloads = 0
    private(set) var ttmlDownloads = 0
    var results: [OnlineTagCandidate] = [candidate]
    var ttmlResults: [AMLLTTMLCandidate] = []
    var failingProvider: OnlineTagProvider?
    var downloaded = content
    var suspended = false
    var continuation: CheckedContinuation<DownloadedLyrics, Never>?
    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] {
        searches += 1
        if provider == failingProvider { throw LyricsDownloadError.unavailable }
        return results.filter { $0.provider == provider }
    }
    func searchTTML(title: String, artist: String) async throws -> [AMLLTTMLCandidate] {
        ttmlSearches += 1
        return ttmlResults
    }
    func downloadTTML(_ candidate: AMLLTTMLCandidate) async throws -> DownloadedLyrics {
        ttmlDownloads += 1
        return DownloadedLyrics(ttml: "<tt><body><p begin=\"1s\" end=\"2s\">TTML</p></body></tt>")
    }
    func download(_ candidate: OnlineTagCandidate, includeTranslation: Bool) async throws -> DownloadedLyrics {
        downloads += 1
        if suspended { return await withCheckedContinuation { continuation = $0 } }
        return downloaded
    }
    func suspend() { suspended = true }
    func resume() { continuation?.resume(returning: downloaded); continuation = nil }
    func setResults(_ results: [OnlineTagCandidate]) { self.results = results }
    func setTTMLResults(_ results: [AMLLTTMLCandidate]) { ttmlResults = results }
    func setFailingProvider(_ provider: OnlineTagProvider?) { failingProvider = provider }
    func setDownloaded(_ lyrics: DownloadedLyrics) { downloaded = lyrics }
}
actor FakeWriter: DownloadedLyricsWriting {
    private(set) var writes = 0
    private(set) var overwrites: [Bool] = []
    private(set) var automaticFlags: [Bool] = []
    private(set) var formats: [DownloadedLyrics.Format] = []
    var exists = false
    func setExists() { exists = true }
    func save(_ lyrics: DownloadedLyrics, for audioURL: URL, overwrite: Bool, automatic: Bool) async throws -> URL {
        if exists && !overwrite { throw LyricsDownloadError.existingFile }
        writes += 1; overwrites.append(overwrite); automaticFlags.append(automatic); formats.append(lyrics.format)
        return audioURL.deletingPathExtension().appendingPathExtension(lyrics.format.rawValue)
    }
}
@main struct Harness {
    @MainActor static func wait(_ predicate: () async -> Bool) async {
        for _ in 0..<2500 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out")
    }
    @MainActor static func main() async throws {
        let xml = "<tt><body><p begin=\"1s\" end=\"2s\"><span begin=\"1s\" end=\"2s\">TTML</span></p></body></tt>"
        let ttmlPayload = try JSONSerialization.data(withJSONObject: ["status": 200, "data": [
            "id": 123, "ncmMusicIds": ["1"], "lyrics": xml
        ]])
        let searchPayload = try JSONSerialization.data(withJSONObject: ["status": 200, "data": ["items": [[
            "id": 123, "musicNames": ["Song"], "artistNames": ["Artist"], "albumNames": ["Album"]
        ]] ]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLyricsURLProtocol.self]
        let networkService = OnlineLyricsService(session: URLSession(configuration: configuration))
        MockLyricsURLProtocol.reply = { request in
            if request.url?.path == "/v1/lyrics/search" { return (200, searchPayload) }
            if request.url?.path == "/v1/lyrics/get" { return (200, ttmlPayload) }
            fatalError("Direct AMLL selection should only use AMLL")
        }
        let ttmlMatches = try await networkService.searchTTML(title: "Song", artist: "Artist")
        expect(ttmlMatches.first?.id == "123", "AMLL search must return a selectable TTML result")
        let directTTML = try await networkService.downloadTTML(ttmlMatches[0])
        expect(directTTML.format == .ttml && directTTML.content == xml, "Selected TTML must retain its source")
        let providerPayload = try JSONSerialization.data(withJSONObject: [
            "code": 200, "lrc": ["lyric": "[00:01.000]Provider"]
        ])
        MockLyricsURLProtocol.reply = { request in
            if request.url?.path == "/v1/lyrics/get" { fatalError("Provider selection must not query AMLL") }
            return (200, providerPayload)
        }
        let providerLRC = try await networkService.download(candidate, includeTranslation: false)
        expect(providerLRC.format == .lrc && providerLRC.lrc.contains("Provider"), "Provider selection must save LRC")

        if CommandLine.arguments.contains("--live-word") {
            let service = OnlineLyricsService()
            let netease = OnlineTagCandidate(provider: .netease, songID: "1392990601", title: "Live YRC", artist: "", album: "", duration: nil, trackNumber: nil)
            let qq = OnlineTagCandidate(provider: .qqMusic, songID: "0039MnYb0qxYhV", title: "Live QRC", artist: "", album: "", duration: nil, trackNumber: nil)
            for candidate in [netease, qq] {
                for includeTranslation in [false, true] {
                    let downloaded = try await service.download(candidate, includeTranslation: includeTranslation)
                    let lines = downloaded.format == .ttml
                        ? TTMLLyricsParser.parse(Data(downloaded.content.utf8))
                        : LyricLine.parseLRC(from: downloaded.lrc)
                    expect(lines.filter { $0.timingSegments?.count ?? 0 > 2 }.count > 10, "Live \(candidate.provider.rawValue) word timing must survive download")
                    expect(lines.allSatisfy { line in line.timingSegments.map { $0.map(\.text).joined() == line.text } ?? true },
                           "Live word segments must match displayed text")
                }
                print("Live \(candidate.provider.rawValue): word-timed lyrics received")
            }
            return
        }
        if CommandLine.arguments.contains("--live") {
            let service = OnlineLyricsService()
            for provider in OnlineTagProvider.allCases {
                let found = try await service.search(provider: provider, title: "稻香", artist: "周杰伦")
                var downloaded = false
                for result in found.prefix(3) {
                    do {
                        let lyrics = try await service.download(result, includeTranslation: true)
                        let lines = lyrics.format == .ttml
                            ? TTMLLyricsParser.parse(Data(lyrics.content.utf8))
                            : LyricLine.parseLRC(from: lyrics.lrc)
                        expect(!lines.isEmpty, "Live lyrics must parse")
                        print("Live \(provider.rawValue): synchronized lyrics received")
                        downloaded = true
                        break
                    } catch LyricsDownloadError.noLyrics { continue }
                }
                expect(downloaded, "Live provider has no lyrics")
            }
            return
        }
        let netease = Data(#"{"code":200,"lrc":{"lyric":"[offset:100]\n[00:01.00]Hello\n[00:02.00]World"},"tlyric":{"lyric":"[00:01.100]你好\n[00:02.100]世界"}}"#.utf8)
        let translated = try OnlineLyricsService.parse(netease, provider: .netease, includeTranslation: true)
        let lines = LyricLine.parseLRC(from: translated.lrc)
        expect(lines.count == 2 && lines[0].text == "Hello / 你好" && lines[0].startTime == 1.1, "Translation and offsets must share one timestamp")
        let plain = try OnlineLyricsService.parse(netease, provider: .netease, includeTranslation: false)
        expect(!plain.lrc.contains("你好"), "Translation toggle must be respected")
        let qq = try OnlineLyricsService.parse(Data(#"{"code":0,"lyric":"&#91;00:01.00&#93;A &amp; B","trans":""}"#.utf8), provider: .qqMusic, includeTranslation: true)
        expect(qq.lrc.contains("A & B"), "QQ entities must decode")
        let yrc = Data(#"{"code":200,"yrc":{"lyric":"[1000,2000](1000,800,0)你(1800,1200,0)好"},"lrc":{"lyric":"[00:01.00]你好"}}"#.utf8)
        let yrcLyrics = try OnlineLyricsService.parse(yrc, provider: .netease, includeTranslation: false)
        let wordLines = LyricLine.parseLRC(from: yrcLyrics.lrc)
        expect(wordLines.count == 1 && wordLines[0].text == "你好" && wordLines[0].timingSegments?.count == 2, "YRC should become word-timed enhanced LRC")
        expect(abs((wordLines[0].timingSegments?[1].startOffset ?? 0) - 0.8) < 0.001, "YRC word offsets must survive")
        let qrcLines = WordTimedLyrics.qrc("[1000,2000]你(1000,800)好(1800,1200)")
        expect(LyricLine.parseLRC(from: WordTimedLyrics.enhancedLRC(qrcLines) ?? "").first?.timingSegments?.count == 2, "QRC word offsets must survive")
        let malformed = Data(#"{"code":200,"yrc":{"lyric":"bad"},"lrc":{"lyric":"[00:01.00]Fallback"}}"#.utf8)
        expect(try OnlineLyricsService.parse(malformed, provider: .netease, includeTranslation: false).lrc.contains("Fallback"), "Malformed YRC must fall back to LRC")
        for payload in [#"{"code":200,"pureMusic":true}"#, #"{"code":200,"lrc":{"lyric":"[ti:Song]"}}"#] {
            do { _ = try OnlineLyricsService.parse(Data(payload.utf8), provider: .netease, includeTranslation: true); fatalError("Expected no lyrics") }
            catch { expect(error as? LyricsDownloadError == .noLyrics, "Must distinguish no lyrics") }
        }
        do { _ = try OnlineLyricsService.parse(Data("<html>blocked</html>".utf8), provider: .netease, includeTranslation: true); fatalError("Expected parse failure") }
        catch { expect(error as? LyricsDownloadError == .invalidResponse, "Invalid data is not no lyrics") }
        let query = LyricsMatchQuery(title: "Song", artist: "Artist", album: "Album", duration: 120)
        expect(query.automaticMatch(in: [candidate]) == candidate, "Exact match should download")
        let exactTTML = AMLLTTMLCandidate(id: "123", title: "Song", artist: "Artist", album: "Album")
        expect(query.automaticTTMLMatch(in: [exactTTML]) == exactTTML, "Exact AMLL metadata should match")
        expect(query.automaticTTMLMatch(in: [exactTTML, exactTTML]) == nil, "Ambiguous AMLL entries must not auto-download")
        expect(LyricsMatchQuery(title: "Song", artist: "Artist", album: "", duration: 120)
            .automaticTTMLMatch(in: [exactTTML]) == nil, "AMLL needs an album without duration metadata")
        let wrong = OnlineTagCandidate(provider: .netease, songID: "2", title: "Song (Live)", artist: "Artist", album: "Album", duration: 120, trackNumber: nil)
        expect(query.automaticMatch(in: [wrong]) == nil, "Live version must not silently replace studio lyrics")
        expect(LyricsMatchQuery(title: "Song", artist: "Artist", album: "Album", duration: 130).automaticMatch(in: [candidate]) == nil, "Duration mismatch must be skipped")
        expect(!LyricsMatchQuery(title: "Song", artist: "Unknown Artist", album: "", duration: 120).isComplete, "Missing artists must not be sent automatically")
        let otherAlbum = OnlineTagCandidate(provider: .qqMusic, songID: "3", title: "Song", artist: "Artist", album: "Other", duration: 120, trackNumber: nil)
        expect(LyricsMatchQuery(title: "Song", artist: "Artist", album: "", duration: 120).automaticMatch(in: [candidate, otherAlbum]) == nil, "Ambiguous albums must require manual choice")
        for c in [candidate, otherAlbum] {
            let request = OnlineLyricsService.request(for: c)
            expect(request.url?.scheme == "https" && request.httpBody == nil, "Lyrics requests must not upload audio")
        }
        let wordRequest = OnlineLyricsService.qqWordRequest(for: otherAlbum)
        expect(wordRequest.httpMethod == "POST" && wordRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"songMID\":\"3\"") == true,
               "QQ word request must contain only the selected song ID")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("音 乐.flac")
        let audioBytes = Data("test audio must stay unchanged".utf8)
        try audioBytes.write(to: audio)
        let writer = DownloadedLyricsFileStore()
        let ttmlURL = try await writer.save(DownloadedLyrics(ttml: xml), for: audio, overwrite: false, automatic: false)
        let savedTTML = try String(contentsOf: ttmlURL, encoding: .utf8)
        expect(ttmlURL.pathExtension == "ttml" && savedTTML == xml,
               "TTML must be written beside the audio as UTF-8")
        try FileManager.default.removeItem(at: ttmlURL)
        let url = try await writer.save(content, for: audio, overwrite: false, automatic: true)
        expect(try String(contentsOf: url, encoding: .utf8) == content.lrc, "UTF-8 sidecar must contain downloaded lyrics")
        do { _ = try await writer.save(DownloadedLyrics(ttml: xml), for: audio, overwrite: false, automatic: true); fatalError("Expected existing LRC protection") }
        catch { expect(error as? LyricsDownloadError == .existingSidecar, "Automatic TTML must not replace existing LRC") }
        do { _ = try await writer.save(translated, for: audio, overwrite: false, automatic: false); fatalError("Expected overwrite protection") }
        catch { expect(error as? LyricsDownloadError == .existingFile, "Manual overwrite requires confirmation") }
        _ = try await writer.save(translated, for: audio, overwrite: true, automatic: false)
        expect(try Data(contentsOf: audio) == audioBytes, "Audio bytes must never change")
        expect(try String(contentsOf: url, encoding: .utf8) == translated.lrc, "Confirmed replacement must publish complete data")
        try FileManager.default.removeItem(at: url)
        let srt = audio.deletingPathExtension().appendingPathExtension("srt")
        try Data("existing user lyrics".utf8).write(to: srt)
        do { _ = try await writer.save(content, for: audio, overwrite: false, automatic: true); fatalError("Expected existing sidecar protection") }
        catch { expect(error as? LyricsDownloadError == .existingSidecar, "Automatic download must preserve all sidecar formats") }
        try FileManager.default.removeItem(at: srt)
        let ttml = audio.deletingPathExtension().appendingPathExtension("ttml")
        try Data("<tt/>".utf8).write(to: ttml)
        do { _ = try await writer.save(content, for: audio, overwrite: false, automatic: true); fatalError("Expected TTML sidecar protection") }
        catch { expect(error as? LyricsDownloadError == .existingSidecar, "Automatic download must preserve TTML") }
        try FileManager.default.removeItem(at: ttml)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: audio)
        do { _ = try await writer.save(content, for: audio, overwrite: true, automatic: false); fatalError("Expected symlink protection") }
        catch { expect(error as? LyricsDownloadError == .unsafeDestination, "Do not follow a lyrics symlink") }
        expect(try Data(contentsOf: audio) == audioBytes, "Symlink must not corrupt audio")
        try FileManager.default.removeItem(at: url)
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 10_000_000)
            return try await writer.save(content, for: audio, overwrite: false, automatic: true)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled write succeeded") } catch {}
        expect(!FileManager.default.fileExists(atPath: url.path), "Cancellation must not create lyrics")

        let defaults = UserDefaults(suiteName: "petrichor.lyrics.test.\(UUID())")!
        let settings = LyricsDownloadSettings(defaults: defaults)
        expect(!settings.automaticallyDownload, "Automatic download is opt-in")
        expect(settings.source == .amll, "AMLL must be the default lyrics source")
        settings.source = .netease
        let service = FakeService(), fakeWriter = FakeWriter()
        await service.setResults([candidate, qqCandidate])
        let track = Track(url: audio)
        let manual = LyricsSearchViewModel(track: track, settings: settings, service: service, writer: fakeWriter, didSave: { _ in })
        expect(await service.searches == 0, "Opening manual search must not contact the network")
        manual.search()
        await wait { !manual.isSearching }
        let platformSearches = await service.searches
        let ttmlSearches = await service.ttmlSearches
        expect(platformSearches == 1 && ttmlSearches == 0,
               "Manual lyrics search must query only the selected source")
        expect(manual.candidates.map(\.sourceName) == ["NetEase Cloud Music"],
               "Manual results must retain their source")
        manual.selection = candidate.id
        manual.title = manual.title
        manual.artist = manual.artist
        manual.selection = manual.selection
        expect(!manual.candidates.isEmpty, "Unchanged control commits must preserve search results")
        expect(await service.downloads == 0, "Search must not download lyrics")
        expect(await fakeWriter.writes == 0, "Search must not write lyrics")
        manual.save()
        await wait { !manual.isSaving }
        expect(manual.savedURL != nil, "Save must succeed without preview")
        expect(await fakeWriter.writes == 1, "Save must write the downloaded lyrics")
        expect(await service.downloads == 1, "Save must download the selected lyrics once")

        let partialService = FakeService()
        await partialService.setResults([candidate, qqCandidate])
        await partialService.setFailingProvider(.netease)
        let partialSearch = LyricsSearchViewModel(track: track, settings: settings, service: partialService, writer: fakeWriter, didSave: { _ in })
        partialSearch.search()
        await wait { !partialSearch.isSearching }
        expect(partialSearch.errorMessage != nil, "A failed selected source must show an error")
        partialSearch.source = .qqMusic
        partialSearch.search()
        await wait { !partialSearch.isSearching }
        expect(partialSearch.candidates.map(\.id) == [qqCandidate.id],
               "Changing source must search the new provider")

        let directService = FakeService(), directWriter = FakeWriter()
        await directService.setTTMLResults([AMLLTTMLCandidate(id: "123", title: "Song", artist: "Artist", album: "Album")])
        settings.source = .amll
        let directSearch = LyricsSearchViewModel(track: track, settings: settings, service: directService, writer: directWriter, didSave: { _ in })
        directSearch.search()
        await wait { !directSearch.isSearching }
        expect(directSearch.candidates.first?.isTTML == true, "AMLL selection must list TTML results")
        expect(await directService.searches == 0, "AMLL selection must not search music providers")
        directSearch.selection = directSearch.candidates.first?.id
        directSearch.save()
        await wait { !directSearch.isSaving }
        expect(directSearch.savedURL?.pathExtension == "ttml", "Selecting TTML must save a TTML file")
        expect(await directService.ttmlDownloads == 1, "Selected TTML should download once")
        await directWriter.setExists()
        directSearch.selection = nil
        directSearch.selection = directSearch.candidates.first?.id
        directSearch.save()
        await wait { !directSearch.isSaving }
        expect(directSearch.needsOverwriteConfirmation && directSearch.overwriteURL?.pathExtension == "ttml",
               "TTML replacement must name the existing TTML file")
        directSearch.save(overwrite: true)
        await wait { !directSearch.isSaving }
        expect(await directService.ttmlDownloads == 2, "Confirmed TTML replacement must reuse the downloaded file")

        await fakeWriter.setExists()
        settings.source = .netease
        let replacement = LyricsSearchViewModel(track: track, settings: settings, service: service, writer: fakeWriter, didSave: { _ in })
        replacement.search()
        await wait { !replacement.isSearching }
        replacement.selection = candidate.id
        replacement.save()
        await wait { !replacement.isSaving }
        expect(replacement.needsOverwriteConfirmation, "Existing LRC must trigger confirmation")
        expect(await fakeWriter.writes == 1, "Unconfirmed save must not replace lyrics")
        replacement.save(overwrite: true)
        await wait { !replacement.isSaving }
        expect(await fakeWriter.overwrites == [false, true], "Only confirmed overwrite may replace lyrics")
        expect(await service.downloads == 2, "Confirmed overwrite must reuse downloaded lyrics")

        await service.suspend()
        replacement.selection = nil
        replacement.selection = candidate.id
        replacement.save()
        await wait { await service.downloads == 3 }
        replacement.selection = nil
        await service.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(await fakeWriter.writes == 2, "Changing selection must cancel the pending save")

        let autoService = FakeService(), autoWriter = FakeWriter()
        let automatic = AutomaticLyricsDownloader(settings: settings, service: autoService, writer: autoWriter, loadLocal: { _ in false }, didSave: { _ in })
        automatic.update(track: track, isPlaying: true)
        expect(await autoService.searches == 0, "Disabled automatic download must not contact the network")
        settings.automaticallyDownload = true
        automatic.update(track: track, isPlaying: true)
        await wait { await autoWriter.writes == 1 }
        expect(await autoWriter.automaticFlags == [true], "Automatic flag must reach writer")
        expect(await autoWriter.overwrites == [false], "Automatic write must never overwrite")
        let autoTTMLService = FakeService(), autoTTMLWriter = FakeWriter()
        await autoTTMLService.setTTMLResults([AMLLTTMLCandidate(id: "123", title: "Song", artist: "Artist", album: "Album")])
        settings.source = .amll
        let autoTTML = AutomaticLyricsDownloader(settings: settings, service: autoTTMLService, writer: autoTTMLWriter, loadLocal: { _ in false }, didSave: { _ in })
        autoTTML.update(track: track, isPlaying: true)
        await wait { await autoTTMLWriter.writes == 1 }
        expect(await autoTTMLWriter.formats == [.ttml], "AMLL automatic download must save TTML")
        expect(await autoTTMLService.searches == 0, "AMLL automatic download must not search music providers")
        settings.source = .netease
        automatic.update(track: nil, isPlaying: false)
        automatic.update(track: track, isPlaying: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        expect(await autoService.searches == 1, "Repeat playback must not repeatedly request lyrics")
        let localService = FakeService()
        let localAuto = AutomaticLyricsDownloader(settings: settings, service: localService, writer: autoWriter, loadLocal: { _ in true }, didSave: { _ in })
        localAuto.update(track: track, isPlaying: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        expect(await localService.searches == 0, "Existing local or embedded lyrics must prevent requests")
        let staleService = FakeService(), staleWriter = FakeWriter()
        await staleService.suspend()
        let staleAuto = AutomaticLyricsDownloader(settings: settings, service: staleService, writer: staleWriter, loadLocal: { _ in false }, didSave: { _ in })
        staleAuto.update(track: track, isPlaying: true)
        await wait { await staleService.downloads == 1 }
        settings.automaticallyDownload = false
        staleAuto.update(track: track, isPlaying: true)
        await staleService.resume()
        try? await Task.sleep(nanoseconds: 20_000_000)
        expect(await staleWriter.writes == 0, "Disabling automatic downloads must cancel pending writes")
        print("Lyrics download parsing, matching, file safety and workflow checks passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/Lyrics/TTMLLyricsParser.swift" \
    "$ROOT_DIR/Core/Lyrics/AMLLTTMLService.swift" \
    "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" \
    "$ROOT_DIR/Core/Metadata/OnlineTagLookup.swift" \
    "$ROOT_DIR/Core/Lyrics/WordTimedLyrics.swift" \
    "$ROOT_DIR/Core/Lyrics/QQMusicQRCDecoder.swift" \
    "$ROOT_DIR/Core/Lyrics/OnlineLyricsService.swift" \
    "$ROOT_DIR/Core/Lyrics/DownloadedLyricsFileStore.swift" \
    "$ROOT_DIR/Managers/LyricsDownloadSettings.swift" \
    "$ROOT_DIR/Managers/LyricsSearchViewModel.swift" \
    "$ROOT_DIR/Managers/AutomaticLyricsDownloader.swift" \
    "$TMP_DIR/Stubs.swift" "$TMP_DIR/Harness.swift" -o "$TMP_DIR/test-lyrics"
"$TMP_DIR/test-lyrics" "$@"
