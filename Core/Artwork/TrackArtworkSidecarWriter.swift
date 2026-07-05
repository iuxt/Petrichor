import Foundation

enum TrackArtworkSidecarWriter {
    struct WriteResult {
        let url: URL
        let didWriteSidecar: Bool
    }

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
        try writeResult(artwork, forAudioURL: audioURL, fileManager: fileManager).url
    }

    static func writeResult(
        _ artwork: Data,
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) throws -> WriteResult {
        if let existing = existingSameStemArtworkURL(forAudioURL: audioURL, fileManager: fileManager) {
            return WriteResult(url: existing, didWriteSidecar: false)
        }

        let sidecarURL = preferredSidecarURL(forAudioURL: audioURL)
        do {
            try artwork.write(to: sidecarURL, options: [.withoutOverwriting])
            return WriteResult(url: sidecarURL, didWriteSidecar: true)
        } catch {
            if let existing = existingSameStemArtworkURL(forAudioURL: audioURL, fileManager: fileManager) {
                return WriteResult(url: existing, didWriteSidecar: false)
            }
            throw error
        }
    }
}
