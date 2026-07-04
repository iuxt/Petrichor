import Foundation

enum ArtistImageStore {
    struct VersionedImageData: Sendable {
        let data: Data
        let cacheKey: String
    }

    static let artistImagesDirectoryName = "artist images"
    private static let preferredImageExtension = "jpg"

    static func imageDirectory(forMusicRoot musicRoot: URL) -> URL {
        musicRoot.appendingPathComponent(artistImagesDirectoryName, isDirectory: true)
    }

    static func preferredImageURL(artistName: String, musicRoot: URL) -> URL {
        imageDirectory(forMusicRoot: musicRoot)
            .appendingPathComponent(sanitizedArtistFilename(artistName))
            .appendingPathExtension(preferredImageExtension)
    }

    static func existingImageURL(
        artistName: String,
        musicRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let filename = sanitizedArtistFilename(artistName)
        let directory = imageDirectory(forMusicRoot: musicRoot)

        for fileExtension in AlbumArtFormat.supportedExtensions {
            let candidate = directory
                .appendingPathComponent(filename)
                .appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func imageData(
        for artistName: String,
        tracks: [Track],
        folders: [Folder],
        fileManager: FileManager = .default
    ) -> Data? {
        versionedImageData(
            for: artistName,
            tracks: tracks,
            folders: folders,
            fileManager: fileManager
        )?.data
    }

    static func imageData(
        for artistName: String,
        tracks: [Track],
        folders: [Folder],
        withFileVersion _: Bool,
        fileManager: FileManager = .default
    ) -> VersionedImageData? {
        versionedImageData(
            for: artistName,
            tracks: tracks,
            folders: folders,
            fileManager: fileManager
        )
    }

    static func versionedImageData(
        for artistName: String,
        tracks: [Track],
        folders: [Folder],
        fileManager: FileManager = .default
    ) -> VersionedImageData? {
        for root in musicRoots(for: artistName, tracks: tracks, folders: folders) {
            guard let imageURL = existingImageURL(
                artistName: artistName,
                musicRoot: root,
                fileManager: fileManager
            ) else {
                continue
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: imageURL.path),
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue <= AlbumArtFormat.maxArtworkSize,
                  let data = try? Data(contentsOf: imageURL),
                  data.count <= AlbumArtFormat.maxArtworkSize else {
                continue
            }

            return VersionedImageData(
                data: data,
                cacheKey: imageCacheKey(
                    imageURL: imageURL,
                    fileSize: fileSize.intValue,
                    modificationDate: attributes[.modificationDate] as? Date
                )
            )
        }

        return nil
    }

    static func groupedArtistsByMusicRoot(
        from tracks: [Track],
        folders: [Folder]
    ) -> [URL: Set<String>] {
        var result: [URL: Set<String>] = [:]
        let unknownArtist = LibraryFilterType.artists.unknownPlaceholder

        for track in tracks {
            guard let root = musicRoot(containing: track.url, folders: folders) else {
                continue
            }

            for artist in ArtistParser.parse(track.artist, unknownPlaceholder: unknownArtist) {
                let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != unknownArtist else { continue }
                result[root, default: []].insert(trimmed)
            }
        }

        return result
    }

    static func musicRoot(containing url: URL, folders: [Folder]) -> URL? {
        let filePath = url.standardizedFileURL.path
        return folders
            .map(\.url)
            .sorted {
                $0.standardizedFileURL.path.count > $1.standardizedFileURL.path.count
            }
            .first { root in
                let rootPath = root.standardizedFileURL.path
                return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
            }
    }

    @discardableResult
    static func writeImage(
        _ data: Data,
        artistName: String,
        musicRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = imageDirectory(forMusicRoot: musicRoot)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = preferredImageURL(artistName: artistName, musicRoot: musicRoot)
        guard !fileManager.fileExists(atPath: destination.path) else {
            return destination
        }

        try data.write(to: destination, options: [.atomic])
        return destination
    }

    static func sanitizedArtistFilename(_ artistName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = artistName.components(separatedBy: invalidCharacters)
        let sanitized = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Unknown Artist" : sanitized
    }

    private static func imageCacheKey(
        imageURL: URL,
        fileSize: Int,
        modificationDate: Date?
    ) -> String {
        let path = imageURL.standardizedFileURL.path
        let version = modificationDate.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "unknown"
        return "\(path)-\(fileSize)-\(version)"
    }

    private static func musicRoots(
        for artistName: String,
        tracks: [Track],
        folders: [Folder]
    ) -> [URL] {
        let normalizedArtistName = ArtistParser.normalizeArtistName(artistName)
        let unknownArtist = LibraryFilterType.artists.unknownPlaceholder
        var seen: Set<String> = []
        var roots: [URL] = []

        for track in tracks {
            let artists = ArtistParser.parse(track.artist, unknownPlaceholder: unknownArtist)
            let hasArtist = artists.contains {
                ArtistParser.normalizeArtistName($0) == normalizedArtistName
            }
            guard hasArtist,
                  let root = musicRoot(containing: track.url, folders: folders) else {
                continue
            }

            let key = root.standardizedFileURL.path
            if seen.insert(key).inserted {
                roots.append(root)
            }
        }

        if !roots.isEmpty {
            return roots
        }

        return musicRoots(containingTracks: tracks, folders: folders)
    }

    private static func musicRoots(containingTracks tracks: [Track], folders: [Folder]) -> [URL] {
        var seen: Set<String> = []
        var roots: [URL] = []

        for track in tracks {
            guard let root = musicRoot(containing: track.url, folders: folders) else {
                continue
            }

            let key = root.standardizedFileURL.path
            if seen.insert(key).inserted {
                roots.append(root)
            }
        }

        return roots
    }
}
