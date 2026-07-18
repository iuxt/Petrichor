import Foundation

struct AlbumMetadataAggregateInput: Equatable, Sendable {
    let trackID: Int64
    let trackNumber: Int?
    let releaseDate: String?
    let year: String
    let totalDiscs: Int?
}

struct AlbumMetadataAggregate: Equatable, Sendable {
    let releaseDate: String?
    let releaseYear: Int?
    let totalDiscs: Int?
}

enum AlbumMetadataAggregator {
    static func aggregate(
        _ tracks: [AlbumMetadataAggregateInput]
    ) -> AlbumMetadataAggregate {
        let ordered = tracks.sorted { lhs, rhs in
            switch (lhs.trackNumber, rhs.trackNumber) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.trackID < rhs.trackID
            }
        }

        let releaseDate = ordered.lazy
            .compactMap { normalized($0.releaseDate) }
            .first
        let releaseYear = year(from: releaseDate)
            ?? ordered.lazy.compactMap { year(from: $0.year) }.first
        let totalDiscs = tracks.compactMap(\.totalDiscs).max()

        return AlbumMetadataAggregate(
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            totalDiscs: totalDiscs
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func year(from value: String?) -> Int? {
        guard let value = normalized(value), value.count >= 4 else {
            return nil
        }
        return Int(value.prefix(4))
    }
}
