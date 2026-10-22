import Darwin
import Foundation

protocol DownloadedArtworkWriting: Sendable {
    func save(_ image: Data, for audioURL: URL, album: String, matchedAlbum: String) async throws -> URL
    func saveManual(_ image: Data, for audioURL: URL, overwrite: Bool) async throws -> URL
    func saveCue(_ image: Data, sheetURL: URL, audioURL: URL, album: String, overwrite: Bool, automatic: Bool) async throws -> URL
}

extension DownloadedArtworkWriting {
    func saveCue(_ image: Data, sheetURL: URL, audioURL: URL, album: String, overwrite: Bool, automatic: Bool) async throws -> URL {
        throw ArtworkDownloadError.unsafeDestination
    }
}

actor DownloadedArtworkFileStore: DownloadedArtworkWriting {
    static let shared = DownloadedArtworkFileStore()

    func save(_ image: Data, for audioURL: URL, album: String, matchedAlbum: String) throws -> URL {
        try Task.checkCancellation()
        guard audioURL.isFileURL, !image.isEmpty,
              image.count <= AlbumArtFormat.maxArtworkSize else { throw ArtworkDownloadError.unsafeDestination }
        let directory = audioURL.deletingLastPathComponent()
        let audioScope = audioURL.startAccessingSecurityScopedResource()
        let directoryScope = directory.startAccessingSecurityScopedResource()
        defer {
            if audioScope { audioURL.stopAccessingSecurityScopedResource() }
            if directoryScope { directory.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioURL.path) else { throw CocoaError(.fileNoSuchFile) }
        let current = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { AlbumArtFormat.isSupported($0.pathExtension) }
        if ExternalArtworkResolver.artworkURL(forAudioURL: audioURL, candidates: current, albumTitle: album) != nil {
            throw ArtworkDownloadError.existingArtwork
        }
        // An exact album match can serve other tracks in the same folder. If its
        // name is unsafe as a single path component, use the audio file's stem.
        let exactAlbum = !album.isEmpty && album != "Unknown Album" &&
            album.folding(options: .caseInsensitive, locale: .current) ==
            matchedAlbum.folding(options: .caseInsensitive, locale: .current)
        let safeAlbum = !album.isEmpty && album != "." && album != ".." &&
            album == album.trimmingCharacters(in: .whitespacesAndNewlines) &&
            album.rangeOfCharacter(from: .controlCharacters) == nil &&
            album == FilesystemUtils.sanitizeFilename(album) && album.count <= 200
        let stem = exactAlbum && safeAlbum ? album : audioURL.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent(stem).appendingPathExtension("jpg")
        let temporary = directory.appendingPathComponent(".petrichor-artwork-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try image.write(to: temporary, options: .withoutOverwriting)
        try Task.checkCancellation()
        // Exclusive publication preserves artwork added manually during download.
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                renamex_np(source!, target!, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            if errno == EEXIST { throw ArtworkDownloadError.existingArtwork }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return destination
    }

    /// A manual selection is specific to one song. Same-stem artwork takes
    /// priority over folder and album covers without changing those shared files.
    func saveManual(_ image: Data, for audioURL: URL, overwrite: Bool) throws -> URL {
        try publish(image, anchorURL: audioURL, destination: audioURL.deletingPathExtension().appendingPathExtension("jpg"), overwrite: overwrite)
    }

    func saveCue(_ image: Data, sheetURL: URL, audioURL: URL, album: String, overwrite: Bool, automatic: Bool) async throws -> URL {
        guard sheetURL.isFileURL, sheetURL.pathExtension.lowercased() == "cue", audioURL.isFileURL,
              FileManager.default.fileExists(atPath: audioURL.path), !(automatic && overwrite) else {
            throw ArtworkDownloadError.unsafeDestination
        }
        if automatic {
            for anchor in [sheetURL, audioURL] {
                let candidates = try FileManager.default.contentsOfDirectory(at: anchor.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                if ExternalArtworkResolver.artworkURL(forAudioURL: anchor, candidates: candidates, albumTitle: album) != nil {
                    throw ArtworkDownloadError.existingArtwork
                }
            }
        }
        return try publish(image, anchorURL: sheetURL, destination: sheetURL.appendingPathExtension("jpg"), overwrite: overwrite)
    }

    private func publish(_ image: Data, anchorURL audioURL: URL, destination: URL, overwrite: Bool) throws -> URL {
        try Task.checkCancellation()
        guard audioURL.isFileURL, !image.isEmpty,
              image.count <= AlbumArtFormat.maxArtworkSize else { throw ArtworkDownloadError.unsafeDestination }
        let directory = audioURL.deletingLastPathComponent()
        let audioScope = audioURL.startAccessingSecurityScopedResource()
        let directoryScope = directory.startAccessingSecurityScopedResource()
        defer {
            if audioScope { audioURL.stopAccessingSecurityScopedResource() }
            if directoryScope { directory.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioURL.path) else { throw CocoaError(.fileNoSuchFile) }
        if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ArtworkDownloadError.unsafeDestination
            }
            guard overwrite else { throw ArtworkDownloadError.existingArtwork }
        }
        let temporary = directory.appendingPathComponent(".petrichor-artwork-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try image.write(to: temporary, options: .withoutOverwriting)
        try Task.checkCancellation()
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                overwrite ? rename(source!, target!) : renamex_np(source!, target!, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            if errno == EEXIST { throw ArtworkDownloadError.existingArtwork }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return destination
    }
}
