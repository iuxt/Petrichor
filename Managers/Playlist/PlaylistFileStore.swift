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

    /// Legacy M3Us use their path as identity. Remember a moved root without
    /// modifying playlist files as a side effect of a library scan.
    static func rememberRelocatedPlaylists(from oldRoot: URL, to newRoot: URL) {
        var identities = UserDefaults.standard.dictionary(forKey: "relocatedPlaylistIDs") as? [String: String] ?? [:]
        for file in M3UPlaylistCodec.playlistFiles(in: newRoot) {
            let oldFile = M3UPlaylistCodec.playlistDirectory(in: oldRoot).appendingPathComponent(file.lastPathComponent)
            identities[file.standardizedFileURL.path] = identities[oldFile.standardizedFileURL.path]
                ?? UUID.stablePlaylistID(for: oldFile.standardizedFileURL.path).uuidString
        }
        UserDefaults.standard.set(identities, forKey: "relocatedPlaylistIDs")
    }

    func loadPlaylists(from folders: [Folder], databaseManager: DatabaseManager) async -> LoadResult {
        var playlists: [Playlist] = []
        var missingEntries: [URL: [String]] = [:]
        var usedNames = Set<String>()
        var usedIDs = Set<UUID>()

        for folder in folders {
            for fileURL in M3UPlaylistCodec.playlistFiles(in: folder.url, fileManager: fileManager) {
                do {
                    try Task.checkCancellation()
                    let content = try M3UPlaylistCodec.readText(from: fileURL)
                    let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
                    let matched = await match(
                        entries: entries,
                        musicFolder: folder.url,
                        fileURL: fileURL,
                        databaseManager: databaseManager
                    )
                    try Task.checkCancellation()
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    let displayName = uniqueName(baseName, usedNames: &usedNames)
                    var playlist = Playlist(
                        name: displayName,
                        tracks: matched.tracks,
                        fileBacking: PlaylistFileBacking(musicFolderURL: folder.url, fileURL: fileURL,
                                                         unresolvedEntries: matched.missing, sourceContent: content)
                    )
                    playlist.trackCount = matched.tracks.count
                    playlist.dateModified = modificationDate(for: fileURL) ?? Date()
                    playlist = playlist.withStableFileBackedID(for: fileURL)
                    if let storedID = Self.persistedID(in: content), !usedIDs.contains(storedID) {
                        playlist.id = storedID
                    }
                    usedIDs.insert(playlist.id)
                    playlists.append(playlist)

                    if !matched.missing.isEmpty {
                        missingEntries[fileURL] = matched.missing
                    }
                } catch is CancellationError {
                    return LoadResult(playlists: [], missingEntries: [:])
                } catch {
                    Logger.error("Failed to read playlist file \(fileURL.path): \(error)")
                }
            }
        }

        return LoadResult(playlists: playlists, missingEntries: missingEntries)
    }

    func createPlaylist(named name: String, tracks: [Track], in defaultFolder: Folder) throws -> Playlist {
        try withSecurityScope(for: defaultFolder.url) {
            let directory = M3UPlaylistCodec.playlistDirectory(in: defaultFolder.url)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = uniqueFileURL(for: name, in: directory)
            var playlist = Playlist(
                name: fileURL.deletingPathExtension().lastPathComponent,
                tracks: tracks,
                fileBacking: PlaylistFileBacking(musicFolderURL: defaultFolder.url, fileURL: fileURL)
            )
            playlist.trackCount = tracks.count
            playlist = playlist.withStableFileBackedID(for: fileURL)
            return try write(tracks: tracks, for: playlist)
        }
    }

    func rename(_ playlist: Playlist, to newName: String) throws -> Playlist {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }

        return try withSecurityScope(for: backing.musicFolderURL) {
            let original = try checkedContent(for: backing)
            let target = uniqueFileURL(
                for: newName,
                in: backing.fileURL.deletingLastPathComponent(),
                excluding: backing.fileURL
            )

            // An M3U comment keeps identity portable across renames and restarts.
            // Preserve all original entries, including currently unresolved ones.
            let content = Self.content(original, preservingID: playlist.id)
            try content.write(to: backing.fileURL, atomically: true, encoding: .utf8)
            if target.standardizedFileURL != backing.fileURL.standardizedFileURL {
                try fileManager.moveItem(at: backing.fileURL, to: target)
            }

            var updated = playlist
            updated.name = target.deletingPathExtension().lastPathComponent
            updated.dateModified = Date()
            updated.fileBacking = PlaylistFileBacking(musicFolderURL: backing.musicFolderURL, fileURL: target,
                                                      unresolvedEntries: backing.unresolvedEntries, sourceContent: content)
            return updated
        }
    }

    func delete(_ playlist: Playlist) throws {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }

        try withSecurityScope(for: backing.musicFolderURL) {
            try moveItemToTrash(backing.fileURL)
        }
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
        var content = M3UPlaylistCodec.render(trackURLs: tracks.map(\.url), musicFolder: backing.musicFolderURL,
                                             playlistFileURL: backing.fileURL)
        for entry in backing.unresolvedEntries { content += entry + "\r\n" }
        content = Self.content(content, preservingID: playlist.id)
        try withSecurityScope(for: backing.musicFolderURL) {
            if backing.sourceContent != nil { _ = try checkedContent(for: backing) }
            try content.write(to: backing.fileURL, atomically: true, encoding: .utf8)
        }

        var updated = playlist
        updated.tracks = tracks
        updated.trackCount = tracks.count
        updated.dateModified = Date()
        updated.fileBacking?.sourceContent = content
        return updated
    }

    private func checkedContent(for backing: PlaylistFileBacking) throws -> String {
        let content = try M3UPlaylistCodec.readText(from: backing.fileURL)
        if let expected = backing.sourceContent, content != expected {
            throw PlaylistFileStoreError.fileChanged
        }
        return content
    }

    private static let identityPrefix = "#PETRICHOR-ID:"

    private static func persistedID(in content: String) -> UUID? {
        content.components(separatedBy: .newlines).lazy.compactMap { line -> UUID? in
            guard line.hasPrefix(identityPrefix) else { return nil }
            return UUID(uuidString: String(line.dropFirst(identityPrefix.count)).trimmingCharacters(in: .whitespaces))
        }.first
    }

    private static func content(_ content: String, preservingID id: UUID) -> String {
        if persistedID(in: content) == id { return content }
        let lines = content.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix(identityPrefix)
        }
        return (["#EXTM3U", identityPrefix + id.uuidString] + lines.filter { $0 != "#EXTM3U" })
            .joined(separator: "\r\n") + "\r\n"
    }

    /// Run `body` while holding a security-scoped resource reference on `folderURL`.
    ///
    /// Playlist files live inside a user-chosen music folder whose access is granted
    /// via a security-scoped bookmark. The app-wide `LibraryManager` retains these
    /// scopes for the app's lifetime, but this store must not *depend* on that: it
    /// takes its own (balanced) reference so writes remain correct even if the
    /// library's retention strategy changes, and stops it in the matching `defer`.
    private func withSecurityScope<T>(for folderURL: URL, _ body: () throws -> T) rethrows -> T {
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
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
            if Task.isCancelled { return ([], []) }
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
    case fileChanged

    var errorDescription: String? {
        switch self {
        case .missingBackingFile:
            return String(appLocalized: "The playlist file could not be found.")
        case .missingDefaultMusicFolder:
            return String(appLocalized: "Add a music folder before creating playlists.")
        case .fileChanged:
            return String(appLocalized: "The playlist file changed outside the app. Reload it before editing again.")
        }
    }
}

extension Playlist {
    func withStableFileBackedID(for fileURL: URL) -> Playlist {
        var copy = self
        let path = fileURL.standardizedFileURL.path
        let identities = UserDefaults.standard.dictionary(forKey: "relocatedPlaylistIDs") as? [String: String] ?? [:]
        copy.id = identities[path].flatMap(UUID.init(uuidString:)) ?? UUID.stablePlaylistID(for: path)
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
