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
        if let embedded = await cachedOrEmbeddedArtwork(for: request) {
            return embedded
        }

        // List the track's directory once and reuse the candidate set for both the
        // same-stem and generic artwork lookups. Previously each miss re-listed the
        // folder, doubling directory IO for every track without embedded artwork.
        let directory = request.audioURL.deletingLastPathComponent()
        let candidates = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        if let sameStemURL = ExternalArtworkResolver.sameStemArtworkURL(forAudioURL: request.audioURL, candidates: candidates),
           let sameStem = cachedOrFileArtwork(for: request, fileURL: sameStemURL) {
            return sameStem
        }

        if let genericURL = ExternalArtworkResolver.genericArtworkURL(forAudioURL: request.audioURL, candidates: candidates),
           let generic = cachedOrFileArtwork(for: request, fileURL: genericURL) {
            return generic
        }

        return nil
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

    private func cachedOrEmbeddedArtwork(for request: ArtworkRequest) async -> Data? {
        guard let key = cacheKey(for: request, sourceURL: request.audioURL) else {
            return nil
        }

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let data = await MetadataEngine.extractEmbeddedArtwork(from: request.audioURL) else {
            return nil
        }

        cache.store(data, for: key)
        return data
    }

    private func cachedOrFileArtwork(for request: ArtworkRequest, fileURL: URL) -> Data? {
        guard let key = cacheKey(for: request, sourceURL: fileURL) else {
            return nil
        }

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let rawData = try? Data(contentsOf: fileURL),
              rawData.count <= AlbumArtFormat.maxArtworkSize,
              let data = ImageUtils.compressImage(from: rawData, source: fileURL.lastPathComponent) else {
            return nil
        }

        cache.store(data, for: key)
        return data
    }

    private func cacheKey(for request: ArtworkRequest, sourceURL: URL) -> ArtworkCacheKey? {
        guard let source = sourceIdentity(for: sourceURL) else { return nil }
        return ArtworkCacheKey(
            kind: request.kind,
            identity: request.identity,
            source: source,
            version: ArtworkCacheKey.currentVersion
        )
    }

    private func sourceIdentity(for sourceURL: URL) -> ArtworkSourceIdentity? {
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
