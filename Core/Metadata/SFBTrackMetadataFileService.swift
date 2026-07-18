import Foundation
import SFBAudioEngine

enum TrackMetadataFileError: LocalizedError {
    case fileMissing(String)
    case unsupportedFormat(String)
    case fileNotWritable(String)
    case readFailed(String)
    case writeFailed(String)
    case verificationFailed([TrackMetadataEditableField])

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            return String.localizedStringWithFormat(
                String(appLocalized: "The file “%1$@” no longer exists."),
                name
            )
        case .unsupportedFormat(let format):
            return String.localizedStringWithFormat(
                String(appLocalized: "The %1$@ format is read-only."),
                format.uppercased()
            )
        case .fileNotWritable(let name):
            return String.localizedStringWithFormat(
                String(appLocalized: "The file “%1$@” is not writable."),
                name
            )
        case .readFailed(let detail):
            return String.localizedStringWithFormat(
                String(appLocalized: "Could not read tags: %1$@"),
                detail
            )
        case .writeFailed(let detail):
            return String.localizedStringWithFormat(
                String(appLocalized: "Could not save tags: %1$@"),
                detail
            )
        case .verificationFailed(let fields):
            let names = fields.map(localizedMetadataFieldName).joined(separator: ", ")
            return String.localizedStringWithFormat(
                String(appLocalized: "Saved tags could not be verified: %1$@"),
                names
            )
        }
    }

    var isPreflightSkip: Bool {
        switch self {
        case .fileMissing, .unsupportedFormat, .fileNotWritable:
            return true
        case .readFailed, .writeFailed, .verificationFailed:
            return false
        }
    }
}

private func localizedMetadataFieldName(
    _ field: TrackMetadataEditableField
) -> String {
    switch field {
    case .title: return String(appLocalized: "Title")
    case .artist: return String(appLocalized: "Artist")
    case .album: return String(appLocalized: "Album")
    case .albumArtist: return String(appLocalized: "Album Artist")
    case .composer: return String(appLocalized: "Composer")
    case .genre: return String(appLocalized: "Genre")
    case .releaseDate: return String(appLocalized: "Release Date")
    case .trackNumber: return String(appLocalized: "Track Number")
    case .trackTotal: return String(appLocalized: "Total Tracks")
    case .discNumber: return String(appLocalized: "Disc Number")
    case .discTotal: return String(appLocalized: "Total Discs")
    case .bpm: return String(appLocalized: "BPM")
    case .compilation: return String(appLocalized: "Compilation")
    case .comment: return String(appLocalized: "Comment")
    }
}

private func apply<Value: Equatable & Sendable>(
    _ patch: MetadataPatchValue<Value>,
    to keyPath: ReferenceWritableKeyPath<AudioMetadata, Value?>,
    on metadata: AudioMetadata
) {
    switch patch {
    case .unchanged:
        break
    case .set(let value):
        metadata[keyPath: keyPath] = value
    case .remove:
        metadata[keyPath: keyPath] = nil
    }
}

actor SFBTrackMetadataFileService {
    static let writableExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "aiff", "aif",
        "ogg", "oga", "opus", "spx", "ape", "mpc",
        "wv", "tta", "dsf", "dff"
    ]

    private let fileManager = FileManager.default

    func load(target: TrackMetadataEditTarget) -> TrackMetadataLoadResult {
        do {
            return .loaded(try loadSnapshot(target: target))
        } catch {
            return .unavailable(
                target: target,
                reason: error.localizedDescription
            )
        }
    }

    func preflightWrite(target: TrackMetadataEditTarget) throws {
        let didStartScope = target.url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                target.url.stopAccessingSecurityScopedResource()
            }
        }

        try validateWritable(target)
        do {
            _ = try AudioFile(readingPropertiesAndMetadataFrom: target.url)
        } catch {
            throw TrackMetadataFileError.readFailed(error.localizedDescription)
        }
    }

    func write(
        target: TrackMetadataEditTarget,
        patch: TrackMetadataPatch
    ) throws -> TrackMetadataSnapshot {
        guard !patch.isEmpty else {
            return try loadSnapshot(target: target)
        }

        let didStartScope = target.url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                target.url.stopAccessingSecurityScopedResource()
            }
        }

        try validateWritable(target)

        let audioFile: AudioFile
        do {
            audioFile = try AudioFile(readingPropertiesAndMetadataFrom: target.url)
        } catch {
            throw TrackMetadataFileError.readFailed(error.localizedDescription)
        }

        let metadata = audioFile.metadata
        apply(patch.title, to: \.title, on: metadata)
        apply(patch.artist, to: \.artist, on: metadata)
        apply(patch.album, to: \.albumTitle, on: metadata)
        apply(patch.albumArtist, to: \.albumArtist, on: metadata)
        apply(patch.composer, to: \.composer, on: metadata)
        apply(patch.genre, to: \.genre, on: metadata)
        apply(patch.releaseDate, to: \.releaseDate, on: metadata)
        apply(patch.trackNumber, to: \.trackNumber, on: metadata)
        apply(patch.trackTotal, to: \.trackTotal, on: metadata)
        apply(patch.discNumber, to: \.discNumber, on: metadata)
        apply(patch.discTotal, to: \.discTotal, on: metadata)
        apply(patch.bpm, to: \.bpm, on: metadata)
        apply(patch.compilation, to: \.isCompilation, on: metadata)
        apply(patch.comment, to: \.comment, on: metadata)

        do {
            try audioFile.writeMetadata()
        } catch {
            throw TrackMetadataFileError.writeFailed(error.localizedDescription)
        }

        let verified = try loadSnapshot(target: target)
        let mismatches = patch.mismatchedFields(in: verified.tags)
        guard mismatches.isEmpty else {
            throw TrackMetadataFileError.verificationFailed(mismatches)
        }
        return verified
    }

    private func loadSnapshot(
        target: TrackMetadataEditTarget
    ) throws -> TrackMetadataSnapshot {
        guard fileManager.fileExists(atPath: target.url.path) else {
            throw TrackMetadataFileError.fileMissing(target.displayName)
        }

        let didStartScope = target.url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                target.url.stopAccessingSecurityScopedResource()
            }
        }

        let audioFile: AudioFile
        do {
            audioFile = try AudioFile(readingPropertiesAndMetadataFrom: target.url)
        } catch {
            throw TrackMetadataFileError.readFailed(error.localizedDescription)
        }

        let metadata = audioFile.metadata
        let tags = TrackEditableTags(
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.albumTitle,
            albumArtist: metadata.albumArtist,
            composer: metadata.composer,
            genre: metadata.genre,
            releaseDate: metadata.releaseDate,
            trackNumber: metadata.trackNumber,
            trackTotal: metadata.trackTotal,
            discNumber: metadata.discNumber,
            discTotal: metadata.discTotal,
            bpm: metadata.bpm,
            compilation: metadata.isCompilation ?? false,
            comment: metadata.comment
        ).normalized()

        let format = target.url.pathExtension.lowercased()
        let isSupported = Self.writableExtensions.contains(format)
        let hasWritePermission = fileManager.isWritableFile(atPath: target.url.path)
        let restrictionReason: String?
        if !isSupported {
            restrictionReason = TrackMetadataFileError
                .unsupportedFormat(format)
                .localizedDescription
        } else if !hasWritePermission {
            restrictionReason = TrackMetadataFileError
                .fileNotWritable(target.displayName)
                .localizedDescription
        } else {
            restrictionReason = nil
        }

        let resourceValues = try? target.url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = resourceValues?.fileSize.map(Int64.init)

        return TrackMetadataSnapshot(
            target: target,
            tags: tags,
            file: TrackMetadataFileSummary(
                filename: target.displayName,
                path: target.url.path,
                format: format,
                duration: audioFile.properties.duration,
                fileSize: fileSize
            ),
            isWritable: isSupported && hasWritePermission,
            restrictionReason: restrictionReason
        )
    }

    private func validateWritable(_ target: TrackMetadataEditTarget) throws {
        guard fileManager.fileExists(atPath: target.url.path) else {
            throw TrackMetadataFileError.fileMissing(target.displayName)
        }
        let format = target.url.pathExtension.lowercased()
        guard Self.writableExtensions.contains(format) else {
            throw TrackMetadataFileError.unsupportedFormat(format)
        }
        guard fileManager.isWritableFile(atPath: target.url.path) else {
            throw TrackMetadataFileError.fileNotWritable(target.displayName)
        }
    }
}
