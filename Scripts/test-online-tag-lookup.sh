#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-online-tags.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation

extension String {
    init(appLocalized key: String) { self = key }
}

func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

func expectError(_ expected: OnlineTagLookupError, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected \(expected)") }
    catch { expect(error as? OnlineTagLookupError == expected, "Wrong error: \(error)") }
}

actor ControlledSearch: OnlineTagSearching {
    private var requests: [Int: CheckedContinuation<[OnlineTagCandidate], Error>] = [:]
    private(set) var count = 0
    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] {
        count += 1
        let index = count
        // Intentionally ignores cancellation to exercise stale-response protection.
        return try await withCheckedThrowingContinuation { requests[index] = $0 }
    }
    func complete(_ index: Int, with result: Result<[OnlineTagCandidate], Error>) {
        requests.removeValue(forKey: index)?.resume(with: result)
    }
}

final class ResponseProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct Harness {
    @MainActor
    static func settle(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for test state")
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let service = OnlineTagLookupService()
            for provider in OnlineTagProvider.allCases {
                let results = try await service.search(provider: provider, title: "Beethoven", artist: "")
                expect(!results.isEmpty, "Live provider returned no candidates")
                print("Live \(provider.rawValue): \(results.count) candidates")
            }
            return
        }

        for provider in OnlineTagProvider.allCases {
            let request = try OnlineTagLookupService.request(provider: provider, title: "  A+B & 月光?#  ", artist: "演奏者")
            let url = request.url!
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let queryName = provider == .netease ? "s" : "w"
            expect(items.first { $0.name == queryName }?.value == "演奏者 A+B & 月光?#", "Unicode and reserved query characters must survive")
            expect(url.scheme == "https", "Search must use HTTPS")
            expect(url.absoluteString.contains("%2B"), "Literal plus must be encoded")
            expect(request.httpBody == nil, "Never upload a file")
            expectError(.emptyQuery) { _ = try OnlineTagLookupService.request(provider: provider, title: " \n", artist: " ") }
        }
        let netease = Data(#"{"code":200,"result":{"songs":[{"id":12345678901,"name":"月光","artists":[{"name":"Artist A"},{"name":"Artist B"}],"album":{"name":"Album"},"duration":201500},{"id":12345678901,"name":"duplicate"},{"id":2,"name":"Partial","position":0},{"name":"missing ID"},null]}}"#.utf8)
        let results = try OnlineTagLookupService.parse(netease, provider: .netease)
        expect(results.count == 2, "Skip malformed rows and duplicate IDs")
        let candidate = results[0]
        expect(candidate.songID == "12345678901", "Preserve 64-bit IDs")
        expect(candidate.artist == "Artist A; Artist B", "Keep all artists")
        expect(candidate.duration == 201.5, "Convert NetEase milliseconds")
        expect(results[1].trackNumber == nil && results[1].fields.count == 1, "Missing fields must not become destructive edits")
        let qq = Data(#"{"code":0,"data":{"song":{"list":[{"songmid":"abc","songname":"Title","singer":[{"name":"Singer"}],"albumname":"Record","interval":180,"cdIdx":4}]}}}"#.utf8)
        let qqCandidate = try OnlineTagLookupService.parse(qq, provider: .qqMusic)[0]
        expect(qqCandidate.duration == 180 && qqCandidate.trackNumber == 4, "QQ duration is seconds and cdIdx is the track number")
        let extreme = try OnlineTagLookupService.parse(Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"Extreme","duration":1e100}]}}"#.utf8), provider: .netease)
        expect(extreme[0].duration == nil, "Untrusted durations must not overflow display formatters")
        expect(try OnlineTagLookupService.parse(Data(#"{"code":200,"result":{"songCount":0}}"#.utf8), provider: .netease).isEmpty, "Zero results is not a failure")
        expectError(.serviceUnavailable) { _ = try OnlineTagLookupService.parse(Data(#"{"code":403}"#.utf8), provider: .netease) }
        expectError(.invalidResponse) { _ = try OnlineTagLookupService.parse(Data("<html>blocked</html>".utf8), provider: .qqMusic) }
        expectError(.invalidResponse) { _ = try OnlineTagLookupService.parse(Data(#"{"code":200,"result":{}}"#.utf8), provider: .netease) }
        expectError(.invalidResponse) { _ = try OnlineTagLookupService.parse(Data(#"{"code":200,"result":{"songs":[{"name":"broken"}]}}"#.utf8), provider: .netease) }

        let original = TrackEditableTags(title: "Local", artist: "Local artist", album: "Local album", albumArtist: "Album artist", composer: "Composer", genre: "Rock", releaseDate: "2020", trackNumber: 7, trackTotal: 12, discNumber: 1, discTotal: 2, bpm: 120, compilation: false, comment: "My notes")
        var form = TrackMetadataEditForm(tags: [original])
        candidate.apply(to: &form, fields: [.title, .trackNumber])
        let patch = try form.makePatch()
        expect(patch.title == .set("月光"), "Chosen title must fill the form")
        expect(patch.artist == .unchanged && patch.album == .unchanged, "Unchecked values must remain unchanged")
        expect(patch.trackNumber == .unchanged, "Absent track number must preserve existing number")
        expect(patch.comment == .unchanged && patch.genre == .unchanged && patch.releaseDate == .unchanged, "Unrelated tags must remain unchanged")
        qqCandidate.apply(to: &form, fields: [.trackNumber])
        expect(try form.makePatch().trackNumber == .set(4), "Available track number must be applied")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponseProtocol.self]
        let service = OnlineTagLookupService(session: URLSession(configuration: config))
        ResponseProtocol.body = netease
        expect(try await service.search(provider: .netease, title: "Test", artist: "") == results, "HTTP response must reach the parser")
        ResponseProtocol.status = 429
        do {
            _ = try await service.search(provider: .netease, title: "Test", artist: "")
            fatalError("HTTP rate limit must fail")
        } catch {
            expect(error as? OnlineTagLookupError == .serviceUnavailable, "HTTP errors must not look like no matches")
        }

        let controlled = ControlledSearch()
        let model = OnlineTagLookupViewModel(title: "First", artist: "", service: controlled)
        expect(await controlled.count == 0, "Opening the dialog must not start a request")
        model.search()
        await settle { await controlled.count == 1 }
        expect(model.isSearching && !model.canSearch, "Show busy state and prevent duplicate requests")
        model.title = "Second"
        expect(!model.isSearching && model.candidates.isEmpty, "Editing query invalidates previous search")
        model.search()
        await settle { await controlled.count == 2 }
        await controlled.complete(2, with: .success([qqCandidate]))
        await settle { !model.isSearching }
        await controlled.complete(1, with: .success(results))
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(model.candidates == [qqCandidate], "Old response must not overwrite new results")
        model.selection = qqCandidate.id
        expect(model.selectedCandidate == qqCandidate, "Selection must resolve to a current candidate")
        model.provider = .qqMusic
        expect(model.selectedCandidate == nil && model.candidates.isEmpty, "Changing provider clears stale selection")
        model.search()
        await settle { await controlled.count == 3 }
        await controlled.complete(3, with: .failure(URLError(.timedOut)))
        await settle { !model.isSearching }
        expect(model.errorMessage?.contains("timed out") == true, "Timeout must be actionable")
        model.search()
        await settle { await controlled.count == 4 }
        model.invalidateSearch()
        await controlled.complete(4, with: .success(results))
        try? await Task.sleep(nanoseconds: 10_000_000)
        expect(model.candidates.isEmpty && model.errorMessage == nil, "Closing must discard pending work")
        print("Online tag lookup checks passed")
    }
}
SWIFT
xcrun swiftc -parse-as-library \
    "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" \
    "$ROOT_DIR/Core/Metadata/OnlineTagLookup.swift" \
    "$ROOT_DIR/Managers/OnlineTagLookupViewModel.swift" \
    "$TMP_DIR/Harness.swift" -o "$TMP_DIR/test-online-tags"
"$TMP_DIR/test-online-tags" "$@"
