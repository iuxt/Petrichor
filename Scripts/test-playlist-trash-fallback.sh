#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/stubs.swift" <<'SWIFT'
import Foundation

struct Track {
    var id = UUID()
    func withRowID(_ id: UUID) -> Track { var copy = self; copy.id = id; return copy }
    var playlistURL: URL { url }
    var trackId: Int64?
    let url: URL
}

struct Folder {
    let url: URL
}

struct Playlist {
    var id = UUID()
    var name: String
    var tracks: [Track]
    var fileBacking: PlaylistFileBacking?
    var trackCount = 0
    var dateModified = Date()
}

final class DatabaseManager {
    func findTrackByPath(_ path: String) async -> Track? {
        nil
    }
}

enum Logger {
    static func info(_ message: String) {}
    static func warning(_ message: String) {}
    static func error(_ message: String) {}
}

enum FilesystemUtils {
    static func sanitizeFilename(_ filename: String) -> String {
        filename
    }
}
SWIFT
sed -n '/^struct PlaylistFileBacking:/,/^}/p' Models/Core/Playlist.swift >> "$tmpdir/stubs.swift"

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

final class FailingTrashFileManager: FileManager {
    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: 3328)
    }
}

final class NilResultTrashFileManager: FileManager {
    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        outResultingURL?.pointee = nil
    }
}

func assertPlaylistDeleteFallsBack(
    fileManager: FileManager,
    playlistName: String,
    line: UInt = #line
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-playlist-trash-\(UUID().uuidString)", isDirectory: true)
    let playlistDirectory = root.appendingPathComponent("playlists", isDirectory: true)
    let playlistURL = playlistDirectory.appendingPathComponent(playlistName).appendingPathExtension("m3u")
    try FileManager.default.createDirectory(at: playlistDirectory, withIntermediateDirectories: true)
    try "#EXTM3U\n".write(to: playlistURL, atomically: true, encoding: .utf8)

    let trashDirectory = try fileManager.url(
        for: .trashDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let fallbackURL = TrackTrashFallback.fallbackURL(
        for: playlistURL,
        trashDirectory: trashDirectory,
        fileManager: fileManager
    )
    try? FileManager.default.removeItem(at: fallbackURL)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    let playlist = Playlist(
        name: playlistName,
        tracks: [],
        fileBacking: PlaylistFileBacking(musicFolderURL: root, fileURL: playlistURL)
    )
    let store = PlaylistFileStore(fileManager: fileManager)

    try store.delete(playlist)

    if FileManager.default.fileExists(atPath: playlistURL.path) {
        fputs("Expected playlist file to be removed after Trash fallback at line \(line)\n", stderr)
        exit(1)
    }

    if !FileManager.default.fileExists(atPath: fallbackURL.path) {
        fputs("Expected playlist file at fallback Trash URL \(fallbackURL.path) at line \(line)\n", stderr)
        exit(1)
    }
}

try assertPlaylistDeleteFallsBack(fileManager: FailingTrashFileManager(), playlistName: "failing-trash-\(UUID().uuidString)")
try assertPlaylistDeleteFallsBack(fileManager: NilResultTrashFileManager(), playlistName: "nil-trash-\(UUID().uuidString)")

print("Playlist Trash fallback checks passed")
SWIFT

swiftc \
    "$tmpdir/stubs.swift" \
    Utilities/LocalizationSettings.swift \
    Core/M3UPlaylistCodec.swift \
    Core/TrackTrashFallback.swift \
    Managers/Playlist/PlaylistFileStore.swift \
    "$tmpdir/main.swift" \
    -o "$tmpdir/test-playlist-trash-fallback"

"$tmpdir/test-playlist-trash-fallback"
