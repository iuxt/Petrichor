#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-artwork-download.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/Stubs.swift" <<'SWIFT'
import Foundation

enum OnlineTagProvider: Sendable { case netease, qqMusic }
struct OnlineTagCandidate: Sendable {
    let provider: OnlineTagProvider
    let songID: String
}
enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png"]
    static let knownFilenames = ["cover", "folder", "album"]
    static let maxArtworkSize = 20 * 1024 * 1024
    static func isSupported(_ ext: String) -> Bool { supportedExtensions.contains(ext.lowercased()) }
}
enum FilesystemUtils {
    static func sanitizeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
enum ImageUtils {
    static func downsampledImage(from data: Data, maxDimension: CGFloat) -> Data? { data.isEmpty ? nil : data }
    static func encodeJPEG(_ image: Data, quality: CGFloat) -> Data? { image }
}
SWIFT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }

@main struct Harness {
    static func main() async throws {
        let netease = OnlineTagCandidate(provider: .netease, songID: "123")
        let qq = OnlineTagCandidate(provider: .qqMusic, songID: "abc123")
        let neteaseURL = try OnlineArtworkService.detailURL(for: netease)
        expect(neteaseURL.scheme == "https" && neteaseURL.path == "/api/song/detail" &&
               URLComponents(url: neteaseURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ids" })?.value == "[123]",
               "NetEase song detail request must use the matched ID")
        let qqURL = try OnlineArtworkService.detailURL(for: qq)
        expect(qqURL.scheme == "https" && qqURL.host == "c.y.qq.com" &&
               URLComponents(url: qqURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "songmid" })?.value == "abc123",
               "QQ song detail request must use the matched MID")

        let neteaseJSON = Data(#"{"songs":[{"id":123,"album":{"picUrl":"https://p1.music.126.net/cover.jpg"}}]}"#.utf8)
        expect(try OnlineArtworkService.imageURL(from: neteaseJSON, for: netease).host == "p1.music.126.net",
               "NetEase should use album.picUrl")
        let httpNeteaseJSON = Data(#"{"songs":[{"id":123,"album":{"picUrl":"http://p1.music.126.net/cover.jpg"}}]}"#.utf8)
        expect(try OnlineArtworkService.imageURL(from: httpNeteaseJSON, for: netease).scheme == "https",
               "Provider HTTP artwork URLs should be upgraded to HTTPS")
        let qqJSON = Data(#"{"data":[{"mid":"abc123","album":{"mid":"album42"}}]}"#.utf8)
        expect(try OnlineArtworkService.imageURL(from: qqJSON, for: qq).absoluteString ==
               "https://y.gtimg.cn/music/photo_new/T002R800x800M000album42.jpg",
               "QQ should use its 800px album cover")
        for bad in [
            Data(#"{"songs":[{"id":999,"album":{"picUrl":"https://p1.music.126.net/cover.jpg"}}]}"#.utf8),
            Data(#"{"songs":[{"id":123,"album":{"picUrl":"https://example.com/cover.jpg"}}]}"#.utf8)
        ] {
            do {
                _ = try OnlineArtworkService.imageURL(from: bad, for: netease)
                fatalError("Unrelated or untrusted artwork should be rejected")
            } catch ArtworkDownloadError.invalidResponse { }
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audio = root.appendingPathComponent("Song.flac")
        try Data("audio".utf8).write(to: audio)
        let store = DownloadedArtworkFileStore()
        let image = Data("jpeg".utf8)
        let albumURL = try await store.save(image, for: audio, album: "Album", matchedAlbum: "Album")
        let savedAlbumImage = try Data(contentsOf: albumURL)
        expect(albumURL.lastPathComponent == "Album.jpg" && savedAlbumImage == image,
               "Matching albums should save a JPEG named after the album")
        do {
            _ = try await store.save(Data("replacement".utf8), for: audio, album: "Album", matchedAlbum: "Album")
            fatalError("Existing artwork must not be replaced")
        } catch ArtworkDownloadError.existingArtwork { }
        expect(try Data(contentsOf: albumURL) == image, "Existing artwork must remain untouched")
        try FileManager.default.removeItem(at: albumURL)
        let songURL = try await store.save(image, for: audio, album: "Different", matchedAlbum: "Other")
        expect(songURL.lastPathComponent == "Song.jpg", "Mismatched albums should use the song filename")
        do {
            _ = try await store.saveManual(Data("new".utf8), for: audio, overwrite: false)
            fatalError("Manual artwork must ask before replacing a same-name JPEG")
        } catch ArtworkDownloadError.existingArtwork { }
        let replacement = Data("new".utf8)
        expect(try await store.saveManual(replacement, for: audio, overwrite: true) == songURL,
               "Confirmed manual artwork should use the song's filename")
        expect(try Data(contentsOf: songURL) == replacement,
               "Confirmed manual artwork should replace only the same-name JPEG")
        expect(try Data(contentsOf: audio) == Data("audio".utf8), "Manual artwork must not change audio")
        try FileManager.default.removeItem(at: songURL)
        let other = root.appendingPathComponent("Other.jpg")
        try Data("other".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: songURL, withDestinationURL: other)
        do {
            _ = try await store.saveManual(replacement, for: audio, overwrite: true)
            fatalError("Manual artwork must not replace a symlink")
        } catch ArtworkDownloadError.unsafeDestination { }
        expect(try Data(contentsOf: other) == Data("other".utf8), "Manual artwork must not follow symlinks")
        let cueRoot = root.appendingPathComponent("cue-album")
        let sourceDirectory = cueRoot.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let cue = cueRoot.appendingPathComponent("Album.cue")
        let cueAudio = sourceDirectory.appendingPathComponent("disc.flac")
        let cueBytes = Data("CUE unchanged".utf8), audioBytes = Data("audio unchanged".utf8)
        try cueBytes.write(to: cue)
        try audioBytes.write(to: cueAudio)
        let cueCover = try await store.saveCue(image, sheetURL: cue, audioURL: cueAudio, album: "Album", overwrite: false, automatic: true)
        expect(cueCover == cue.appendingPathExtension("jpg"), "CUE cover belongs beside the sheet, including multi-file albums")
        do {
            _ = try await store.saveCue(replacement, sheetURL: cue, audioURL: cueAudio, album: "Album", overwrite: false, automatic: true)
            fatalError("Automatic CUE cover must not overwrite")
        } catch ArtworkDownloadError.existingArtwork {}
        _ = try await store.saveCue(replacement, sheetURL: cue, audioURL: cueAudio, album: "Album", overwrite: true, automatic: false)
        expect(try Data(contentsOf: cueCover) == replacement, "Explicit album cover replacement is supported")
        expect(try Data(contentsOf: cue) == cueBytes && Data(contentsOf: cueAudio) == audioBytes, "Artwork never edits the CUE or audio")
        try FileManager.default.removeItem(at: cueCover)
        let sharedCover = cueRoot.appendingPathComponent("folder.jpg")
        try image.write(to: sharedCover)
        do {
            _ = try await store.saveCue(replacement, sheetURL: cue, audioURL: cueAudio, album: "Album", overwrite: false, automatic: true)
            fatalError("Automatic CUE artwork must respect existing folder covers")
        } catch ArtworkDownloadError.existingArtwork {}
        try FileManager.default.createSymbolicLink(at: cueCover, withDestinationURL: sharedCover)
        do {
            _ = try await store.saveCue(replacement, sheetURL: cue, audioURL: cueAudio, album: "Album", overwrite: true, automatic: false)
            fatalError("Manual CUE artwork must not replace symlinks")
        } catch ArtworkDownloadError.unsafeDestination {}
        expect(try Data(contentsOf: sharedCover) == image, "Shared folder cover survives CUE replacement attempts")
        print("Artwork endpoint and sidecar storage checks passed")
    }
}
SWIFT

swiftc -parse-as-library \
    "$TMP_DIR/Stubs.swift" \
    "$ROOT_DIR/Core/Metadata/ExternalArtworkResolver.swift" \
    "$ROOT_DIR/Core/Artwork/OnlineArtworkService.swift" \
    "$ROOT_DIR/Core/Artwork/DownloadedArtworkFileStore.swift" \
    "$TMP_DIR/main.swift" -o "$TMP_DIR/test-artwork-download"
"$TMP_DIR/test-artwork-download" "$TMP_DIR"
