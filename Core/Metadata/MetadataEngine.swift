import Foundation

// MARK: - Track Metadata

struct TrackMetadata {
    let url: URL
    var title: String?
    var artist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: String?
    var duration: Double = 0
    var albumArtist: String?
    var trackNumber: Int?
    var totalTracks: Int?
    var discNumber: Int?
    var totalDiscs: Int?
    var rating: Int?
    var compilation: Bool = false
    var releaseDate: String?
    var originalReleaseDate: String?
    var bpm: Int?
    var mediaType: String?
    var bitrate: Int?
    var sampleRate: Int?
    var channels: Int?
    var codec: String?
    var bitDepth: Int?
    var lossless: Bool?

    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var sortAlbumArtist: String?

    var extended: ExtendedMetadata

    init(url: URL) {
        self.url = url
        self.extended = ExtendedMetadata()
    }
}

// MARK: - Metadata Reader

/// Backend-agnostic contract for reading a file's tags, audio properties, and
/// artwork into a `TrackMetadata`. Concrete readers live in their own files and
/// hold only engine-specific code.
protocol MetadataReader {
    func extractMetadata(from url: URL) async -> TrackMetadata

    func extractEmbeddedArtwork(from url: URL) async -> Data?
}

// MARK: - Metadata Engine

enum MetadataEngine {
    /// Extract metadata from an audio file using the selected backend's reader.
    /// - Parameter url: The URL of the audio file
    /// - Returns: TrackMetadata containing all extracted information
    static func extractMetadata(from url: URL) async -> TrackMetadata {
        await reader().extractMetadata(from: url)
    }

    /// Extract only embedded artwork from an audio file.
    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        await reader().extractEmbeddedArtwork(from: url)
    }

    /// Builds the reader for the selected backend.
    private static func reader() -> MetadataReader {
        switch MediaBackend.current {
        case .sfb:
            return SFBMetadataReader()
        case .crescendo:
            return CrescendoMetadataReader()
        }
    }
}
