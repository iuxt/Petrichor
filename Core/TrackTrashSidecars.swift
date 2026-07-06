import Foundation

enum TrackTrashSidecars {
    static let lyricExtensions = ["lrc", "srt"]
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
        var urls: [URL] = []

        for ext in lyricExtensions {
            let lyricURL = audioURL.deletingPathExtension().appendingPathExtension(ext)
            if fileManager.fileExists(atPath: lyricURL.path) {
                urls.append(lyricURL)
            }
        }

        guard shouldTrashDirectoryArtwork(
            afterRemovingAudioURL: audioURL,
            in: directory,
            fileManager: fileManager
        ) else {
            return urls
        }

        urls.append(contentsOf: artworkURLs(in: directory, fileManager: fileManager))
        return urls
    }

    private static func shouldTrashDirectoryArtwork(
        afterRemovingAudioURL audioURL: URL,
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        let removedPath = audioURL.standardizedFileURL.path
        return !contents.contains { url in
            guard isRegularFile(url, fileManager: fileManager) else { return false }
            guard supportedAudioExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return url.standardizedFileURL.path != removedPath
        }
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
