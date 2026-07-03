import CryptoKit
import Foundation

final class PlaylistFileStore {
    struct LoadResult {
        let playlists: [Playlist]
        let missingEntries: [URL: [String]]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadPlaylists(from folders: [Folder], databaseManager: DatabaseManager) async -> LoadResult {
        var playlists: [Playlist] = []
        var missingEntries: [URL: [String]] = [:]
        var usedNames = Set<String>()

        for folder in folders {
            for fileURL in M3UPlaylistCodec.playlistFiles(in: folder.url, fileManager: fileManager) {
                do {
                    let content = try M3UPlaylistCodec.readText(from: fileURL)
                    let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
                    let matched = await match(
                        entries: entries,
                        musicFolder: folder.url,
                        fileURL: fileURL,
                        databaseManager: databaseManager
                    )
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    let displayName = uniqueName(baseName, usedNames: &usedNames)
                    var playlist = Playlist(
                        name: displayName,
                        tracks: matched.tracks,
                        fileBacking: PlaylistFileBacking(musicFolderURL: folder.url, fileURL: fileURL)
                    )
                    playlist.trackCount = matched.tracks.count
                    playlist.dateModified = modificationDate(for: fileURL) ?? Date()
                    playlist = playlist.withStableFileBackedID(for: fileURL)
                    playlists.append(playlist)

                    if !matched.missing.isEmpty {
                        missingEntries[fileURL] = matched.missing
                    }
                } catch {
                    Logger.error("Failed to read playlist file \(fileURL.path): \(error)")
                }
            }
        }

        return LoadResult(playlists: playlists, missingEntries: missingEntries)
    }

    func createPlaylist(named name: String, tracks: [Track], in defaultFolder: Folder) throws -> Playlist {
        let directory = M3UPlaylistCodec.playlistDirectory(in: defaultFolder.url)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = uniqueFileURL(for: name, in: directory)
        try write(tracks: tracks, to: fileURL, musicFolder: defaultFolder.url)

        var playlist = Playlist(
            name: fileURL.deletingPathExtension().lastPathComponent,
            tracks: tracks,
            fileBacking: PlaylistFileBacking(musicFolderURL: defaultFolder.url, fileURL: fileURL)
        )
        playlist.trackCount = tracks.count
        return playlist.withStableFileBackedID(for: fileURL)
    }

    func rename(_ playlist: Playlist, to newName: String) throws -> Playlist {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }

        let target = uniqueFileURL(
            for: newName,
            in: backing.fileURL.deletingLastPathComponent(),
            excluding: backing.fileURL
        )

        try fileManager.moveItem(at: backing.fileURL, to: target)

        var updated = playlist
        updated.name = target.deletingPathExtension().lastPathComponent
        updated.dateModified = Date()
        updated.fileBacking = PlaylistFileBacking(musicFolderURL: backing.musicFolderURL, fileURL: target)
        return updated.withStableFileBackedID(for: target)
    }

    func delete(_ playlist: Playlist) throws {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }

        try moveItemToTrash(backing.fileURL)
    }

    private func moveItemToTrash(_ url: URL) throws {
        var resultingURL: NSURL?

        do {
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            Logger.warning("System Trash failed for playlist \(url.path), falling back to user Trash: \(error)")
            try moveItemToLocalTrashFallback(url)
            return
        }

        if let resultingURL {
            Logger.info("Moved playlist to Trash: \(url.path) -> \(resultingURL.path ?? "")")
        } else {
            Logger.warning("System Trash returned no destination for playlist \(url.path), falling back to user Trash")
            try moveItemToLocalTrashFallback(url)
        }
    }

    private func moveItemToLocalTrashFallback(_ url: URL) throws {
        let trashDirectory = try fileManager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appTrashDirectory = trashDirectory.appendingPathComponent(TrackTrashFallback.appTrashFolderName, isDirectory: true)
        try fileManager.createDirectory(at: appTrashDirectory, withIntermediateDirectories: true)

        let destination = TrackTrashFallback.fallbackURL(for: url, trashDirectory: trashDirectory, fileManager: fileManager)
        try fileManager.moveItem(at: url, to: destination)
        Logger.info("Moved playlist to local Trash fallback: \(url.path) -> \(destination.path)")
    }

    func write(tracks: [Track], for playlist: Playlist) throws -> Playlist {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }

        try write(tracks: tracks, to: backing.fileURL, musicFolder: backing.musicFolderURL)

        var updated = playlist
        updated.tracks = tracks
        updated.trackCount = tracks.count
        updated.dateModified = Date()
        return updated
    }

    private func write(tracks: [Track], to fileURL: URL, musicFolder: URL) throws {
        let content = M3UPlaylistCodec.render(trackURLs: tracks.map(\.url), musicFolder: musicFolder)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func match(
        entries: [String],
        musicFolder: URL,
        fileURL: URL,
        databaseManager: DatabaseManager
    ) async -> (tracks: [Track], missing: [String]) {
        var tracks: [Track] = []
        var missing: [String] = []
        var seen = Set<Int64>()

        for entry in entries {
            var matched: Track?
            for path in M3UPlaylistCodec.pathVariations(for: entry, musicFolder: musicFolder, playlistFileURL: fileURL) {
                if let track = await databaseManager.findTrackByPath(path) {
                    matched = track
                    break
                }
            }

            if let matched, let trackId = matched.trackId, seen.insert(trackId).inserted {
                tracks.append(matched)
            } else if matched == nil {
                missing.append(entry)
            }
        }

        return (tracks, missing)
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func uniqueName(_ name: String, usedNames: inout Set<String>) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
        var candidate = base
        var suffix = 2

        while usedNames.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }

        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func uniqueFileURL(for name: String, in directory: URL, excluding currentURL: URL? = nil) -> URL {
        let base = FilesystemUtils.sanitizeFilename(name)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("m3u")
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) && candidate != currentURL {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("m3u")
            suffix += 1
        }

        return candidate
    }
}

enum PlaylistFileStoreError: LocalizedError {
    case missingBackingFile
    case missingDefaultMusicFolder

    var errorDescription: String? {
        switch self {
        case .missingBackingFile:
            return String(appLocalized: "The playlist file could not be found.")
        case .missingDefaultMusicFolder:
            return String(appLocalized: "Add a music folder before creating playlists.")
        }
    }
}

extension Playlist {
    func withStableFileBackedID(for fileURL: URL) -> Playlist {
        var copy = self
        copy.id = UUID.stablePlaylistID(for: fileURL.standardizedFileURL.path)
        return copy
    }
}

extension UUID {
    fileprivate static func stablePlaylistID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
