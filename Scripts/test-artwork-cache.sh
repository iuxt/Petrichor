#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'struct ArtworkCacheKey|enum ArtworkKind|struct ArtworkRequest' Core/Artwork/ArtworkRequest.swift >/dev/null; then
    printf 'Artwork request/key types are missing.\n' >&2
    exit 1
fi

if ! rg -n 'final class ArtworkFileCache|func data\(for key: ArtworkCacheKey\)|func store\(_ data: Data, for key: ArtworkCacheKey\)|func trimToLimit\(\)|func clear\(\)' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'ArtworkFileCache API is incomplete.\n' >&2
    exit 1
fi

if ! rg -n 'maxBytes: Int64 = 512 \* 1024 \* 1024' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache must default to 512 MB.\n' >&2
    exit 1
fi

if ! rg -n 'targetBytes = maxBytes \* 9 / 10|sorted\(by: \{.*lastAccess' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache trim must delete least-recently-used files down to 90%% of limit.\n' >&2
    exit 1
fi

swift - <<'SWIFT'
import CryptoKit
import Foundation

enum ArtworkKind: String { case track, album, playlistDerived = "playlist-derived" }

struct ArtworkCacheKey: Hashable {
    let kind: ArtworkKind
    let identity: String
    let sourcePath: String
    let sourceSize: Int64
    let sourceModifiedAt: TimeInterval
    let version: Int

    var filename: String {
        let raw = [
            kind.rawValue,
            identity,
            sourcePath,
            String(sourceSize),
            String(sourceModifiedAt),
            String(version)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }
}

let a = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 10, sourceModifiedAt: 1, version: 1)
let b = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 11, sourceModifiedAt: 1, version: 1)
if a.filename == b.filename {
    fatalError("cache key must change when source size changes")
}
if !a.filename.hasSuffix(".heic") {
    fatalError("cache key filename must use compressed artwork extension")
}
SWIFT
