import Foundation

enum TrackTrashSidecars {
    static let lyricExtensions = ["ttml", "ksc", "lrc", "srt"]
    // Reuse the canonical format lists so a newly-supported audio/artwork extension
    // is recognized here automatically. Hand-maintaining a parallel copy risks
    // trashing directory cover art when the audio set grows but this list doesn't
    // (the scanner would then see "no remaining audio file" and remove the art).
    private static let supportedAudioExtensions: Set<String> = Set(AudioFormat.supportedExtensions.map { $0.lowercased() })
    private static let supportedArtworkExtensions: Set<String> = Set(AlbumArtFormat.supportedExtensions.map { $0.lowercased() })
    private static let knownArtworkFilenames: Set<String> = Set(AlbumArtFormat.knownFilenames.map { $0.lowercased() })

    static func sidecarURLs(
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let directory = audioURL.deletingLastPathComponent()
        // If enumeration fails, ownership is unknown: preserve all sidecars.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        let removedPath = audioURL.standardizedFileURL.path
        let remainingAudio = contents.filter { url in
            url.standardizedFileURL.path != removedPath
                && supportedAudioExtensions.contains(url.pathExtension.lowercased())
                && isRegularFile(url, fileManager: fileManager)
        }
        let stem = audioURL.deletingPathExtension().lastPathComponent
        // Conservatively preserve case variants too, including on case-insensitive volumes.
        let sharesLyrics = remainingAudio.contains {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(stem) == .orderedSame
        }
        var urls: [URL] = []
        if !sharesLyrics {
            for ext in lyricExtensions {
                let lyricURL = audioURL.deletingPathExtension().appendingPathExtension(ext)
                if fileManager.fileExists(atPath: lyricURL.path) { urls.append(lyricURL) }
            }
        }
        if remainingAudio.isEmpty {
            urls.append(contentsOf: artworkURLs(in: directory, fileManager: fileManager))
        }
        return urls
    }

    private static func artworkURLs(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            guard isRegularFile(url, fileManager: fileManager) else { return false }
            guard supportedArtworkExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return knownArtworkFilenames.contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return fileManager.fileExists(atPath: url.path)
        }
        return values.isRegularFile == true
    }
}
