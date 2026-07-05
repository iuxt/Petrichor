import Foundation

enum TrackArtworkSidecarWriter {
    static func preferredSidecarURL(forAudioURL audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("jpg")
    }

    static func existingSameStemArtworkURL(
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let baseURL = audioURL.deletingPathExtension()

        for fileExtension in AlbumArtFormat.supportedExtensions {
            let candidate = baseURL.appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    @discardableResult
    static func write(
        _ artwork: Data,
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let existing = existingSameStemArtworkURL(forAudioURL: audioURL, fileManager: fileManager) {
            return existing
        }

        let sidecarURL = preferredSidecarURL(forAudioURL: audioURL)
        try artwork.write(to: sidecarURL, options: [.withoutOverwriting])
        return sidecarURL
    }
}
