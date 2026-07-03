import Foundation

final class ArtworkResolver {
    static let shared = ArtworkResolver()

    private let cache: ArtworkFileCache
    private let fileManager: FileManager

    init(cache: ArtworkFileCache = .shared, fileManager: FileManager = .default) {
        self.cache = cache
        self.fileManager = fileManager
    }

    func artworkData(for request: ArtworkRequest) async -> Data? {
        guard let source = sourceIdentity(for: request.audioURL) else { return nil }
        let key = ArtworkCacheKey(
            kind: request.kind,
            identity: request.identity,
            source: source,
            version: ArtworkCacheKey.currentVersion
        )

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let data = await resolveUncachedArtwork(for: request.audioURL) else { return nil }
        cache.store(data, for: key)
        return data
    }

    func clearCache() {
        cache.clear()
    }

    func trimCache() {
        cache.trimToLimit()
    }

    func cacheSize() -> Int64 {
        cache.cacheSize()
    }

    private func resolveUncachedArtwork(for audioURL: URL) async -> Data? {
        if let externalURL = externalArtworkURL(for: audioURL),
           let externalData = try? Data(contentsOf: externalURL),
           let compressed = ImageUtils.compressImage(from: externalData, source: externalURL.lastPathComponent) {
            return compressed
        }

        return await MetadataEngine.extractEmbeddedArtwork(from: audioURL)
    }

    private func externalArtworkURL(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return ExternalArtworkResolver.artworkURL(forAudioURL: audioURL, candidates: candidates)
    }

    private func sourceIdentity(for audioURL: URL) -> ArtworkSourceIdentity? {
        let sourceURL = externalArtworkURL(for: audioURL) ?? audioURL
        guard let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return ArtworkSourceIdentity(
            path: sourceURL.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }
}
