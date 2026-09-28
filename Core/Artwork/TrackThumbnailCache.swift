import AppKit
import Foundation

/// List-only cache. Reads of decoded images are synchronous; all loading stays
/// off the main thread. Workers never retain rows or playback/menu closures.
actor TrackThumbnailCache {
    static let shared = TrackThumbnailCache()

    typealias Loader = @Sendable (ArtworkRequest) async -> NSImage?

    struct CachedImage {
        let image: NSImage? // nil is a cached miss, not an absent entry
    }

    private struct Job {
        let id = UUID()
        var waiters: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
        var prefetch = false
    }

    private let loader: Loader
    private let pendingLimit: Int
    private let workerLimit: Int
    private nonisolated let memory: ThumbnailMemoryCache
    private var jobs: [ArtworkRequest: Job] = [:]
    private var pending: [ArtworkRequest] = []
    private var workers: [UUID: Task<Void, Never>] = [:]

    // 4,096 thumbnails at at most 80×80 RGBA pixels use about 100 MiB of bitmap
    // storage. Keep a 4,000-track library warm without retaining original artwork.
    init(cacheLimit: Int = 4096, pendingLimit: Int = 64, workerLimit: Int = 2,
         missLifetime: TimeInterval = 60, loader: @escaping Loader = { await TrackThumbnailCache.load($0) }) {
        precondition(cacheLimit > 0 && pendingLimit > 0 && workerLimit > 0)
        self.memory = ThumbnailMemoryCache(limit: cacheLimit, missLifetime: missLifetime)
        self.pendingLimit = pendingLimit
        self.workerLimit = workerLimit
        self.loader = loader
    }

    /// No task, disk access or decoding: a reused cell can draw the image in its
    /// very first frame. The memory store uses a short, constant-time lock.
    nonisolated func cachedImage(for request: ArtworkRequest) -> CachedImage? {
        memory.lookup(request)
    }

    /// Cache hits bypass the optional scroll debounce. Only a cache miss waits,
    /// then checks again because another row may have loaded it in the meantime.
    func image(for request: ArtworkRequest, delayIfMissing: UInt64 = 0, prefetch: Bool = false) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let entry = cachedImage(for: request) {
            return entry.image
        }
        if delayIfMissing > 0 {
            do { try await Task.sleep(nanoseconds: delayIfMissing) }
            catch { return nil }
            return await image(for: request, prefetch: prefetch)
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if jobs[request] != nil {
                    jobs[request]?.waiters[waiterID] = continuation
                    // A prefetched row entering the viewport takes precedence
                    // over the remaining offscreen work.
                    if !prefetch, jobs[request]?.prefetch == true {
                        jobs[request]?.prefetch = false
                        if let index = pending.firstIndex(of: request) {
                            pending.remove(at: index)
                            pending.append(request)
                        }
                    }
                    return
                }
                // Drop obsolete work rather than building a queue the size of the library.
                if pending.count == pendingLimit {
                    guard !prefetch else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let oldest = pending.removeFirst()
                    if let job = jobs.removeValue(forKey: oldest) {
                        for waiter in job.waiters.values { waiter.resume(returning: nil) }
                    }
                }
                var job = Job()
                job.prefetch = prefetch
                job.waiters[waiterID] = continuation
                jobs[request] = job
                if prefetch { pending.insert(request, at: 0) }
                else { pending.append(request) }
                startWorkers()
            }
        } onCancel: {
            Task { await self.cancel(request, waiterID: waiterID) }
        }
    }

    func removeAll() {
        memory.removeAll()
        pending.removeAll()
        let previous = jobs
        jobs.removeAll()
        for job in previous.values {
            for waiter in job.waiters.values { waiter.resume(returning: nil) }
        }
        // Keep active slots occupied until the underlying readers actually finish.
        for worker in workers.values { worker.cancel() }
    }

    private func cancel(_ request: ArtworkRequest, waiterID: UUID) {
        guard var job = jobs[request], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: nil)
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: request)
            pending.removeAll { $0 == request }
            workers[job.id]?.cancel()
        } else {
            jobs[request] = job
        }
    }

    private func startWorkers() {
        while workers.count < workerLimit, let request = pending.popLast() {
            guard let job = jobs[request] else { continue }
            let id = job.id
            let loader = self.loader
            workers[id] = Task.detached(priority: .utility) { [weak self] in
                let image = Task.isCancelled ? nil : await loader(request)
                await self?.finish(request, id: id, image: image, cancelled: Task.isCancelled)
            }
        }
    }

    private func finish(_ request: ArtworkRequest, id: UUID, image: NSImage?, cancelled: Bool) {
        workers.removeValue(forKey: id)
        if let job = jobs[request], job.id == id {
            jobs.removeValue(forKey: request)
            if !cancelled {
                memory.insert(image, for: request)
            }
            for waiter in job.waiters.values { waiter.resume(returning: cancelled ? nil : image) }
        }
        startWorkers()
    }

    // Small, inspectable invariants for the 4,000-row stress regression.
    struct Statistics {
        let cached: Int
        let pending: Int
        let active: Int
        let waiters: Int
    }

    var statistics: Statistics {
        Statistics(cached: memory.count, pending: pending.count, active: workers.count,
                   waiters: jobs.values.reduce(0) { $0 + $1.waiters.count })
    }

    private nonisolated static func load(_ request: ArtworkRequest) async -> NSImage? {
        guard !Task.isCancelled,
              let data = await ArtworkResolver.shared.artworkData(for: request),
              !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let image = ImageUtils.downsampledImage(
                from: data, maxDimension: CGFloat(ArtworkRequest.thumbnailPixelSize)
            ) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}

/// One bounded store shared by synchronous UI reads and asynchronous loaders.
/// The linked LRU uses dictionary keys rather than reference cycles; neither
/// lookup nor eviction scans the library while holding the lock.
private final class ThumbnailMemoryCache: @unchecked Sendable {
    private struct Entry {
        let result: TrackThumbnailCache.CachedImage
        let expiresAt: Date?
        var newer: ArtworkRequest?
        var older: ArtworkRequest?
    }
    private let lock = NSLock()
    private let limit: Int
    private let missLifetime: TimeInterval
    private var entries: [ArtworkRequest: Entry] = [:]
    private var newest: ArtworkRequest?
    private var oldest: ArtworkRequest?

    init(limit: Int, missLifetime: TimeInterval) {
        self.limit = limit
        self.missLifetime = missLifetime
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func lookup(_ request: ArtworkRequest) -> TrackThumbnailCache.CachedImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[request] else { return nil }
        if let expiry = entry.expiresAt, expiry <= Date() {
            unlink(entry)
            entries.removeValue(forKey: request)
            return nil
        }
        if newest != request {
            unlink(entry)
            prepend(entry, for: request)
        }
        return entry.result
    }

    func insert(_ image: NSImage?, for request: ArtworkRequest) {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[request] {
            unlink(existing)
        } else if entries.count >= limit, let oldest, let entry = entries[oldest] {
            unlink(entry)
            entries.removeValue(forKey: oldest)
        }
        prepend(Entry(result: .init(image: image),
                      expiresAt: image == nil ? Date().addingTimeInterval(missLifetime) : nil), for: request)
    }

    func removeAll() {
        lock.lock()
        let discarded = entries
        entries = [:]
        newest = nil
        oldest = nil
        lock.unlock()
        // Release the image storage outside the lock used by scrolling cells.
        withExtendedLifetime(discarded) {}
    }

    // All linkage mutations happen under lock.
    private func unlink(_ entry: Entry) {
        if let newer = entry.newer { entries[newer]?.older = entry.older }
        else { newest = entry.older }
        if let older = entry.older { entries[older]?.newer = entry.newer }
        else { oldest = entry.newer }
    }

    private func prepend(_ entry: Entry, for request: ArtworkRequest) {
        var entry = entry
        entry.newer = nil
        entry.older = newest
        if let newest { entries[newest]?.newer = request }
        else { oldest = request }
        entries[request] = entry
        newest = request
    }
}
