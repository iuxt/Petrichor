import Foundation

enum ExternalArtworkResolver {
    private static let genericArtworkNames: [String] = uniqueLowercaseValues(
        AlbumArtFormat.knownFilenames
    )
    private static let extensionPriority: [String] = uniqueLowercaseValues(
        AlbumArtFormat.supportedExtensions
    )

    static func artworkURL(forAudioURL audioURL: URL, candidates: [URL]) -> URL? {
        let directoryPath = audioURL.deletingLastPathComponent().standardizedFileURL.path
        let supportedCandidates = candidates.filter { candidate in
            AlbumArtFormat.isSupported(candidate.pathExtension)
                && candidate.deletingLastPathComponent().standardizedFileURL.path == directoryPath
        }
        guard !supportedCandidates.isEmpty else { return nil }

        let audioStem = normalizedStem(audioURL)
        let sameNameCandidates = supportedCandidates.filter { normalizedStem($0) == audioStem }
        if let sameNameArtwork = preferredArtworkURL(from: sameNameCandidates) {
            return sameNameArtwork
        }

        let genericCandidates = supportedCandidates.filter {
            genericArtworkNames.contains(normalizedStem($0))
        }
        return preferredArtworkURL(from: genericCandidates)
    }

    private static func preferredArtworkURL(from candidates: [URL]) -> URL? {
        candidates.sorted { lhs, rhs in
            let lhsNamePriority = artworkNamePriority(lhs)
            let rhsNamePriority = artworkNamePriority(rhs)
            if lhsNamePriority != rhsNamePriority {
                return lhsNamePriority < rhsNamePriority
            }

            let lhsExtensionPriority = fileExtensionPriority(lhs)
            let rhsExtensionPriority = fileExtensionPriority(rhs)
            if lhsExtensionPriority != rhsExtensionPriority {
                return lhsExtensionPriority < rhsExtensionPriority
            }

            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func artworkNamePriority(_ url: URL) -> Int {
        genericArtworkNames.firstIndex(of: normalizedStem(url)) ?? 0
    }

    private static func fileExtensionPriority(_ url: URL) -> Int {
        extensionPriority.firstIndex(of: url.pathExtension.lowercased()) ?? Int.max
    }

    private static func normalizedStem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func uniqueLowercaseValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in values {
            let normalized = value.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }

        return result
    }
}
