import Foundation

enum TrackTrashSidecars {
    static let lyricExtensions = ["lrc", "srt"]
    private static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "aiff", "aif", "alac",
        "flac", "ogg", "oga", "opus", "ape", "mpc", "wv",
        "tta", "spx", "dsf", "dff", "mod", "it", "s3m", "xm",
        "au"
    ]
    private static let supportedArtworkExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]
    private static let knownArtworkFilenames: Set<String> = ["cover", "folder", "album", "artwork", "front"]

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
