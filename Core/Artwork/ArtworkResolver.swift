import Foundation

final class ArtworkResolver {
    static let shared = ArtworkResolver()

    private let cache: ArtworkFileCache
    private let fileManager: FileManager
    private let loadLimiter = ArtworkLoadLimiter()
    private let missingEmbedded = NSCache<NSString, NSDate>()
    private let directories = NSCache<NSString, DirectoryArtwork>()

    private final class DirectoryArtwork {
        let modifiedAt: Date?
        let expiresAt = Date().addingTimeInterval(5)
        let candidates: [URL]
        init(modifiedAt: Date?, candidates: [URL]) {
            self.modifiedAt = modifiedAt
            self.candidates = candidates
        }
    }

    init(cache: ArtworkFileCache = .shared, fileManager: FileManager = .default) {
        self.cache = cache
        self.fileManager = fileManager
        missingEmbedded.countLimit = 8192
        directories.countLimit = 128
        directories.totalCostLimit = 8192
    }

    func artworkData(for request: ArtworkRequest) async -> Data? {
        guard await loadLimiter.acquire() else { return nil }
        let data = await resolveArtwork(for: request)
        // Keep the permit until decoding actually finishes, even if the row was
        // cancelled while a backend was reading a file.
        await loadLimiter.release()
        return Task.isCancelled ? nil : data
    }

    private func resolveArtwork(for request: ArtworkRequest) async -> Data? {
        guard !Task.isCancelled else { return nil }
        if let embedded = await cachedOrEmbeddedArtwork(for: request) {
            return embedded
        }
        guard !Task.isCancelled else { return nil }

        // List the track's directory once and reuse the candidate set for both the
        // same-stem and generic artwork lookups. Previously each miss re-listed the
        // folder, doubling directory IO for every track without embedded artwork.
        let directory = request.audioURL.deletingLastPathComponent()
        let candidates = artworkCandidates(in: directory)

        if let sameStemURL = ExternalArtworkResolver.sameStemArtworkURL(forAudioURL: request.audioURL, candidates: candidates),
           let sameStem = cachedOrFileArtwork(for: request, fileURL: sameStemURL) {
            return sameStem
        }

        if let albumTitle = request.albumTitle,
           let albumNamedURL = ExternalArtworkResolver.albumNamedArtworkURL(
               forAudioURL: request.audioURL,
               albumTitle: albumTitle,
               candidates: candidates
           ),
           let albumNamed = cachedOrFileArtwork(for: request, fileURL: albumNamedURL) {
            return albumNamed
        }

        if let genericURL = ExternalArtworkResolver.genericArtworkURL(forAudioURL: request.audioURL, candidates: candidates),
           let generic = cachedOrFileArtwork(for: request, fileURL: genericURL) {
            return generic
        }

        return nil
    }

    func invalidateMemoryCache() {
        missingEmbedded.removeAllObjects()
        directories.removeAllObjects()
    }

    func clearCache() {
        invalidateMemoryCache()
        cache.clear()
        Task { await TrackThumbnailCache.shared.removeAll() }
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

        let missKey = key.filename as NSString
        if let expiry = missingEmbedded.object(forKey: missKey), expiry.timeIntervalSinceNow > 0 {
            return nil
        }
        if let cached = cache.data(for: key) {
            return cached
        }

        let data: Data?
        if request.kind == .trackThumbnail {
            let raw = await MetadataEngine.extractRawEmbeddedArtwork(from: request.audioURL)
            data = raw.flatMap(thumbnailData)
        } else {
            data = await MetadataEngine.extractEmbeddedArtwork(from: request.audioURL)
        }
        guard !Task.isCancelled else { return nil }
        guard let data else {
            missingEmbedded.setObject(Date().addingTimeInterval(60) as NSDate, forKey: missKey)
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

        guard !Task.isCancelled,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= AlbumArtFormat.maxArtworkSize,
              let rawData = try? Data(contentsOf: fileURL),
              rawData.count <= AlbumArtFormat.maxArtworkSize,
              let data = request.kind == .trackThumbnail
                ? thumbnailData(rawData)
                : ImageUtils.compressImage(from: rawData, source: fileURL.lastPathComponent) else {
            return nil
        }

        cache.store(data, for: key)
        return data
    }

    private func cacheKey(for request: ArtworkRequest, sourceURL: URL) -> ArtworkCacheKey? {
        guard let source = sourceIdentity(for: sourceURL) else { return nil }
        return ArtworkCacheKey(
            kind: request.kind,
            // A folder cover has one thumbnail even when thousands of tracks use it.
            identity: request.kind == .trackThumbnail ? source.path : request.identity,
            source: source,
            version: ArtworkCacheKey.currentVersion
        )
    }

    private func sourceIdentity(for sourceURL: URL) -> ArtworkSourceIdentity? {
        // URL may retain previously read resource values across a metadata edit.
        // Cache validation must compare the current file, not that URL's snapshot.
        var sourceURL = sourceURL
        sourceURL.removeAllCachedResourceValues()
        guard let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return ArtworkSourceIdentity(
            path: sourceURL.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private func thumbnailData(_ raw: Data) -> Data? {
        guard !Task.isCancelled, raw.count <= AlbumArtFormat.maxArtworkSize else { return nil }
        return autoreleasepool {
            guard let image = ImageUtils.downsampledImage(
                from: raw, maxDimension: CGFloat(ArtworkRequest.thumbnailPixelSize)
            ) else { return nil }
            return ImageUtils.encodeJPEG(image, quality: 0.85)
        }
    }

    private func artworkCandidates(in directory: URL) -> [URL] {
        var directory = directory
        directory.removeAllCachedResourceValues()
        let key = directory.path as NSString
        let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let entry = directories.object(forKey: key),
           entry.modifiedAt == modified, entry.expiresAt > Date() {
            return entry.candidates
        }
        let candidates = ((try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { AlbumArtFormat.isSupported($0.pathExtension) }
        // Never retain an entire large music directory or an unbounded image listing.
        if candidates.count <= 1024 {
            directories.setObject(DirectoryArtwork(modifiedAt: modified, candidates: candidates),
                                  forKey: key, cost: max(1, candidates.count))
        }
        return candidates
    }
}
