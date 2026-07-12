import CryptoKit
import Foundation

enum ArtworkKind: String, Sendable {
    case track
    case album
    case playlistDerived = "playlist-derived"
}

struct ArtworkSourceIdentity: Hashable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: TimeInterval
}

struct ArtworkCacheKey: Hashable, Sendable {
    static let currentVersion = 1

    let kind: ArtworkKind
    let identity: String
    let source: ArtworkSourceIdentity
    let version: Int

    var filename: String {
        let raw = [
            kind.rawValue,
            identity,
            source.path,
            String(source.size),
            String(source.modifiedAt),
            String(version)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }
}

struct ArtworkRequest: Hashable, Sendable {
    let kind: ArtworkKind
    let identity: String
    let audioURL: URL
    let albumTitle: String?

    static func track(_ url: URL) -> ArtworkRequest {
        ArtworkRequest(kind: .track, identity: url.standardizedFileURL.path, audioURL: url, albumTitle: nil)
    }

    static func album(albumId: Int64?, representativeTrackURL: URL, albumTitle: String? = nil) -> ArtworkRequest {
        let albumIdentity = albumId.map { "album:\($0)" } ?? "album:\(representativeTrackURL.standardizedFileURL.path)"
        return ArtworkRequest(kind: .album, identity: albumIdentity, audioURL: representativeTrackURL, albumTitle: albumTitle)
    }
}
