import Foundation

enum MetadataPatchValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
    case remove
}

enum TrackMetadataEditableField: String, CaseIterable, Equatable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case composer
    case genre
    case releaseDate
    case trackNumber
    case trackTotal
    case discNumber
    case discTotal
    case bpm
    case compilation
    case comment

    var localizedDisplayName: String {
        switch self {
        case .title: return String(localized: "Title")
        case .artist: return String(localized: "Artist")
        case .album: return String(localized: "Album")
        case .albumArtist: return String(localized: "Album Artist")
        case .composer: return String(localized: "Composer")
        case .genre: return String(localized: "Genre")
        case .releaseDate: return String(localized: "Release Date")
        case .trackNumber: return String(localized: "Track Number")
        case .trackTotal: return String(localized: "Total Tracks")
        case .discNumber: return String(localized: "Disc Number")
        case .discTotal: return String(localized: "Total Discs")
        case .bpm: return String(localized: "BPM")
        case .compilation: return String(localized: "Compilation")
        case .comment: return String(localized: "Comment")
        }
    }
}

struct TrackMetadataEditTarget: Hashable, Sendable {
    let trackID: Int64?
    let url: URL

    var displayName: String {
        url.lastPathComponent
    }
}

struct TrackEditableTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var releaseDate: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var bpm: Int?
    var compilation: Bool
    var comment: String?

    func normalized() -> Self {
        var copy = self
        copy.title = Self.normalizedString(title)
        copy.artist = Self.normalizedString(artist)
        copy.album = Self.normalizedString(album)
        copy.albumArtist = Self.normalizedString(albumArtist)
        copy.composer = Self.normalizedString(composer)
        copy.genre = Self.normalizedString(genre)
        copy.releaseDate = Self.normalizedString(releaseDate)
        copy.comment = Self.normalizedString(comment)
        return copy
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct TrackMetadataFileSummary: Equatable, Sendable {
    let filename: String
    let path: String
    let format: String
    let duration: Double?
    let fileSize: Int64?
}

struct TrackMetadataSnapshot: Equatable, Sendable {
    let target: TrackMetadataEditTarget
    let tags: TrackEditableTags
    let file: TrackMetadataFileSummary
    let isWritable: Bool
    let restrictionReason: String?
}

enum TrackMetadataLoadResult: Sendable {
    case loaded(TrackMetadataSnapshot)
    case unavailable(target: TrackMetadataEditTarget, reason: String)
}

enum TrackMetadataBatchOutcome: Equatable, Sendable {
    case saved
    case skipped(String)
    case failed(String)
}

struct TrackMetadataBatchResult: Identifiable, Equatable, Sendable {
    let target: TrackMetadataEditTarget
    let outcome: TrackMetadataBatchOutcome

    var id: TrackMetadataEditTarget { target }

    static func retryTargets(
        from results: [TrackMetadataBatchResult]
    ) -> [TrackMetadataEditTarget] {
        results.compactMap { result in
            if case .failed = result.outcome {
                return result.target
            }
            return nil
        }
    }
}

struct TrackMetadataValidationError: LocalizedError, Equatable {
    let field: TrackMetadataEditableField
    let message: String

    var errorDescription: String? {
        message
    }
}

struct TrackMetadataPatch: Equatable, Sendable {
    var title: MetadataPatchValue<String> = .unchanged
    var artist: MetadataPatchValue<String> = .unchanged
    var album: MetadataPatchValue<String> = .unchanged
    var albumArtist: MetadataPatchValue<String> = .unchanged
    var composer: MetadataPatchValue<String> = .unchanged
    var genre: MetadataPatchValue<String> = .unchanged
    var releaseDate: MetadataPatchValue<String> = .unchanged
    var trackNumber: MetadataPatchValue<Int> = .unchanged
    var trackTotal: MetadataPatchValue<Int> = .unchanged
    var discNumber: MetadataPatchValue<Int> = .unchanged
    var discTotal: MetadataPatchValue<Int> = .unchanged
    var bpm: MetadataPatchValue<Int> = .unchanged
    var compilation: MetadataPatchValue<Bool> = .unchanged
    var comment: MetadataPatchValue<String> = .unchanged

    var isEmpty: Bool {
        [
            title.isUnchanged,
            artist.isUnchanged,
            album.isUnchanged,
            albumArtist.isUnchanged,
            composer.isUnchanged,
            genre.isUnchanged,
            releaseDate.isUnchanged,
            trackNumber.isUnchanged,
            trackTotal.isUnchanged,
            discNumber.isUnchanged,
            discTotal.isUnchanged,
            bpm.isUnchanged,
            compilation.isUnchanged,
            comment.isUnchanged
        ].allSatisfy { $0 }
    }

    func mismatchedFields(in actual: TrackEditableTags) -> [TrackMetadataEditableField] {
        let actual = actual.normalized()
        var mismatches: [TrackMetadataEditableField] = []
        compare(title, actual.title, field: .title, into: &mismatches)
        compare(artist, actual.artist, field: .artist, into: &mismatches)
        compare(album, actual.album, field: .album, into: &mismatches)
        compare(albumArtist, actual.albumArtist, field: .albumArtist, into: &mismatches)
        compare(composer, actual.composer, field: .composer, into: &mismatches)
        compare(genre, actual.genre, field: .genre, into: &mismatches)
        compare(releaseDate, actual.releaseDate, field: .releaseDate, into: &mismatches)
        compare(trackNumber, actual.trackNumber, field: .trackNumber, into: &mismatches)
        compare(trackTotal, actual.trackTotal, field: .trackTotal, into: &mismatches)
        compare(discNumber, actual.discNumber, field: .discNumber, into: &mismatches)
        compare(discTotal, actual.discTotal, field: .discTotal, into: &mismatches)
        compare(bpm, actual.bpm, field: .bpm, into: &mismatches)
        compare(compilation, Optional(actual.compilation), field: .compilation, into: &mismatches)
        compare(comment, actual.comment, field: .comment, into: &mismatches)
        return mismatches
    }
}

private extension MetadataPatchValue {
    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

private func compare<Value: Equatable & Sendable>(
    _ patch: MetadataPatchValue<Value>,
    _ actual: Value?,
    field: TrackMetadataEditableField,
    into mismatches: inout [TrackMetadataEditableField]
) {
    let matches: Bool
    switch patch {
    case .unchanged:
        matches = true
    case .set(let expected):
        matches = actual == expected
    case .remove:
        matches = actual == nil
    }
    if !matches {
        mismatches.append(field)
    }
}

struct BatchTextFieldState: Equatable, Sendable {
    private let initialText: String
    private let wasMixed: Bool
    private(set) var text: String
    private(set) var isDirty = false

    init(values: [String?]) {
        let normalized = values.map { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let first = normalized.first ?? nil
        wasMixed = normalized.dropFirst().contains { $0 != first }
        initialText = wasMixed ? "" : (first ?? "")
        text = initialText
    }

    var showsMixedPlaceholder: Bool {
        wasMixed && !isDirty && text.isEmpty
    }

    mutating func setText(_ newValue: String) {
        if wasMixed {
            isDirty = true
        } else {
            isDirty = newValue != initialText
        }
        text = newValue
    }

    func stringPatch(multiline: Bool = false) -> MetadataPatchValue<String> {
        guard isDirty else { return .unchanged }
        let patchText = multiline ? text : Self.flattenedSingleLineText(text)
        let trimmed = patchText.trimmingCharacters(
            in: multiline ? .whitespacesAndNewlines : .whitespaces
        )
        return trimmed.isEmpty ? .remove : .set(trimmed)
    }

    private static func flattenedSingleLineText(_ value: String) -> String {
        var result = ""
        var isInNewlineSequence = false

        for scalar in value.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if !isInNewlineSequence {
                    result.append(" ")
                }
                isInNewlineSequence = true
            } else {
                result.append(contentsOf: String(scalar))
                isInNewlineSequence = false
            }
        }

        return result
    }
}

struct BatchCompilationState: Equatable, Sendable {
    private(set) var value: Bool?
    private(set) var isDirty = false

    init(values: [Bool]) {
        let first = values.first ?? false
        value = values.dropFirst().contains { $0 != first } ? nil : first
    }

    mutating func setValue(_ newValue: Bool) {
        value = newValue
        isDirty = true
    }

    var patch: MetadataPatchValue<Bool> {
        guard isDirty, let value else { return .unchanged }
        return .set(value)
    }
}

struct TrackMetadataEditForm: Equatable, Sendable {
    var title: BatchTextFieldState
    var artist: BatchTextFieldState
    var album: BatchTextFieldState
    var albumArtist: BatchTextFieldState
    var composer: BatchTextFieldState
    var genre: BatchTextFieldState
    var releaseDate: BatchTextFieldState
    var trackNumber: BatchTextFieldState
    var trackTotal: BatchTextFieldState
    var discNumber: BatchTextFieldState
    var discTotal: BatchTextFieldState
    var bpm: BatchTextFieldState
    var compilation: BatchCompilationState
    var comment: BatchTextFieldState

    init(tags: [TrackEditableTags]) {
        title = BatchTextFieldState(values: tags.map(\.title))
        artist = BatchTextFieldState(values: tags.map(\.artist))
        album = BatchTextFieldState(values: tags.map(\.album))
        albumArtist = BatchTextFieldState(values: tags.map(\.albumArtist))
        composer = BatchTextFieldState(values: tags.map(\.composer))
        genre = BatchTextFieldState(values: tags.map(\.genre))
        releaseDate = BatchTextFieldState(values: tags.map(\.releaseDate))
        trackNumber = BatchTextFieldState(values: tags.map { $0.trackNumber.map(String.init) })
        trackTotal = BatchTextFieldState(values: tags.map { $0.trackTotal.map(String.init) })
        discNumber = BatchTextFieldState(values: tags.map { $0.discNumber.map(String.init) })
        discTotal = BatchTextFieldState(values: tags.map { $0.discTotal.map(String.init) })
        bpm = BatchTextFieldState(values: tags.map { $0.bpm.map(String.init) })
        compilation = BatchCompilationState(values: tags.map(\.compilation))
        comment = BatchTextFieldState(values: tags.map(\.comment))
    }

    mutating func setText(_ value: String, for field: TrackMetadataEditableField) {
        switch field {
        case .title:
            title.setText(value)
        case .artist:
            artist.setText(value)
        case .album:
            album.setText(value)
        case .albumArtist:
            albumArtist.setText(value)
        case .composer:
            composer.setText(value)
        case .genre:
            genre.setText(value)
        case .releaseDate:
            releaseDate.setText(value)
        case .trackNumber:
            trackNumber.setText(value)
        case .trackTotal:
            trackTotal.setText(value)
        case .discNumber:
            discNumber.setText(value)
        case .discTotal:
            discTotal.setText(value)
        case .bpm:
            bpm.setText(value)
        case .comment:
            comment.setText(value)
        case .compilation:
            break
        }
    }

    mutating func setCompilation(_ value: Bool) {
        compilation.setValue(value)
    }

    func makePatch() throws -> TrackMetadataPatch {
        var patch = TrackMetadataPatch()
        patch.title = title.stringPatch()
        patch.artist = artist.stringPatch()
        patch.album = album.stringPatch()
        patch.albumArtist = albumArtist.stringPatch()
        patch.composer = composer.stringPatch()
        patch.genre = genre.stringPatch()
        patch.releaseDate = try datePatch(from: releaseDate)
        patch.trackNumber = try positiveIntegerPatch(from: trackNumber, field: .trackNumber)
        patch.trackTotal = try positiveIntegerPatch(from: trackTotal, field: .trackTotal)
        patch.discNumber = try positiveIntegerPatch(from: discNumber, field: .discNumber)
        patch.discTotal = try positiveIntegerPatch(from: discTotal, field: .discTotal)
        patch.bpm = try positiveIntegerPatch(from: bpm, field: .bpm)
        patch.compilation = compilation.patch
        patch.comment = comment.stringPatch(multiline: true)
        return patch
    }

    var isDirty: Bool {
        title.isDirty || artist.isDirty || album.isDirty || albumArtist.isDirty || composer.isDirty ||
            genre.isDirty || releaseDate.isDirty || trackNumber.isDirty || trackTotal.isDirty ||
            discNumber.isDirty || discTotal.isDirty || bpm.isDirty || compilation.isDirty || comment.isDirty
    }

    func text(for field: TrackMetadataEditableField) -> String {
        switch field {
        case .title: title.text
        case .artist: artist.text
        case .album: album.text
        case .albumArtist: albumArtist.text
        case .composer: composer.text
        case .genre: genre.text
        case .releaseDate: releaseDate.text
        case .trackNumber: trackNumber.text
        case .trackTotal: trackTotal.text
        case .discNumber: discNumber.text
        case .discTotal: discTotal.text
        case .bpm: bpm.text
        case .compilation: ""
        case .comment: comment.text
        }
    }

    func showsMixedPlaceholder(for field: TrackMetadataEditableField) -> Bool {
        switch field {
        case .title: title.showsMixedPlaceholder
        case .artist: artist.showsMixedPlaceholder
        case .album: album.showsMixedPlaceholder
        case .albumArtist: albumArtist.showsMixedPlaceholder
        case .composer: composer.showsMixedPlaceholder
        case .genre: genre.showsMixedPlaceholder
        case .releaseDate: releaseDate.showsMixedPlaceholder
        case .trackNumber: trackNumber.showsMixedPlaceholder
        case .trackTotal: trackTotal.showsMixedPlaceholder
        case .discNumber: discNumber.showsMixedPlaceholder
        case .discTotal: discTotal.showsMixedPlaceholder
        case .bpm: bpm.showsMixedPlaceholder
        case .compilation: false
        case .comment: comment.showsMixedPlaceholder
        }
    }

    private func positiveIntegerPatch(
        from state: BatchTextFieldState,
        field: TrackMetadataEditableField
    ) throws -> MetadataPatchValue<Int> {
        switch state.stringPatch() {
        case .unchanged:
            return .unchanged
        case .remove:
            return .remove
        case .set(let text):
            guard let value = Int(text), value > 0 else {
                throw TrackMetadataValidationError(
                    field: field,
                    message: String.localizedStringWithFormat(
                        String(localized: "%1$@ must be a positive integer."),
                        field.localizedDisplayName
                    )
                )
            }
            return .set(value)
        }
    }

    private func datePatch(
        from state: BatchTextFieldState
    ) throws -> MetadataPatchValue<String> {
        switch state.stringPatch() {
        case .unchanged:
            return .unchanged
        case .remove:
            return .remove
        case .set(let value):
            guard Self.isValidReleaseDate(value) else {
                throw TrackMetadataValidationError(
                    field: .releaseDate,
                    message: String(
                        localized: "The release date must use YYYY or YYYY-MM-DD."
                    )
                )
            }
            return .set(value)
        }
    }

    private static func isValidReleaseDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        if bytes.count == 4 {
            return bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
        }

        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ bytes[$0] >= 48 && bytes[$0] <= 57 })
        else {
            return false
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
