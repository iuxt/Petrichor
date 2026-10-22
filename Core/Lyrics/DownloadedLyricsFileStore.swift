import Darwin
import Foundation

protocol DownloadedLyricsWriting: Sendable {
    func save(_ lyrics: DownloadedLyrics, for audioURL: URL, overwrite: Bool, automatic: Bool) async throws -> URL
    func save(_ lyrics: DownloadedLyrics, target: LyricsFileTarget, overwrite: Bool, automatic: Bool) async throws -> URL
}

extension DownloadedLyricsWriting {
    func save(_ lyrics: DownloadedLyrics, target: LyricsFileTarget, overwrite: Bool, automatic: Bool) async throws -> URL {
        guard target.cueSheetURL == nil else { throw LyricsDownloadError.unsafeDestination }
        return try await save(lyrics, for: target.audioURL, overwrite: overwrite, automatic: automatic)
    }
}

actor DownloadedLyricsFileStore: DownloadedLyricsWriting {
    static let shared = DownloadedLyricsFileStore()

    func save(_ lyrics: DownloadedLyrics, for audioURL: URL, overwrite: Bool = false, automatic: Bool = false) async throws -> URL {
        try await save(lyrics, target: LyricsFileTarget(audioURL: audioURL), overwrite: overwrite, automatic: automatic)
    }

    func save(_ lyrics: DownloadedLyrics, target: LyricsFileTarget, overwrite: Bool = false, automatic: Bool = false) async throws -> URL {
        let audioURL = target.audioURL
        let anchor = target.anchorURL
        try Task.checkCancellation()
        guard anchor.isFileURL, audioURL.isFileURL else { throw LyricsDownloadError.unsafeDestination }
        let directory = anchor.deletingLastPathComponent()
        let anchorScope = anchor.startAccessingSecurityScopedResource()
        let audioScope = audioURL.startAccessingSecurityScopedResource()
        let directoryScope = directory.startAccessingSecurityScopedResource()
        defer {
            if anchorScope { anchor.stopAccessingSecurityScopedResource() }
            if audioScope { audioURL.stopAccessingSecurityScopedResource() }
            if directoryScope { directory.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioURL.path) else { throw CocoaError(.fileNoSuchFile) }
        guard manager.fileExists(atPath: anchor.path),
              target.cueSheetURL == nil || (target.cueSheetURL?.pathExtension.lowercased() == "cue" && (1...99).contains(target.cueTrackNumber ?? 0)) else {
            throw LyricsDownloadError.unsafeDestination
        }
        let destination = target.destination(extension: lyrics.format.rawValue)
        if automatic {
            let base = target.baseURL.lastPathComponent.lowercased()
            let names = try manager.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() }
            if ["ttml", "ksc", "lrc", "srt"].contains(where: { names.contains(base + "." + $0) }) {
                throw LyricsDownloadError.existingSidecar
            }
        }
        if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LyricsDownloadError.unsafeDestination }
            guard overwrite && !automatic else { throw LyricsDownloadError.existingFile }
        }
        guard !lyrics.content.isEmpty else { throw LyricsDownloadError.noLyrics }
        let temporary = directory.appendingPathComponent(".petrichor-lyrics-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try Data(lyrics.content.utf8).write(to: temporary, options: .withoutOverwriting)
        try Task.checkCancellation()
        // Atomic publish; exclusive rename never replaces an existing file, including a racing
        // manual download. rename() replaces the directory entry, never a symlink target.
        let status = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                overwrite && !automatic ? rename(source!, target!) : renamex_np(source!, target!, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            let code = errno
            if code == EEXIST { throw LyricsDownloadError.existingFile }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return destination
    }
}
