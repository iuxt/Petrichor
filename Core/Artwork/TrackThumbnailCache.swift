import AppKit
import Foundation

/// List-only cache. All bookkeeping is isolated from the main actor; workers
/// contain only a request, never a row or its playback/menu closures.
actor TrackThumbnailCache {
    static let shared = TrackThumbnailCache()

    typealias Loader = @Sendable (ArtworkRequest) async -> NSImage?

    private struct Entry {
        let image: NSImage? // nil is a cached miss, not an absent entry
        let expiresAt: Date
        var lastUsed: UInt64
    }

    private struct Job {
        let id = UUID()
        var waiters: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
    }

    private let loader: Loader
    private let cacheLimit: Int
    private let pendingLimit: Int
    private let workerLimit: Int
    private let lifetime: TimeInterval
    private var cache: [ArtworkRequest: Entry] = [:]
    private var jobs: [ArtworkRequest: Job] = [:]
    private var pending: [ArtworkRequest] = []
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var clock: UInt64 = 0

    init(cacheLimit: Int = 256, pendingLimit: Int = 64, workerLimit: Int = 2,
         lifetime: TimeInterval = 60, loader: @escaping Loader = { await TrackThumbnailCache.load($0) }) {
        precondition(cacheLimit > 0 && pendingLimit > 0 && workerLimit > 0)
        self.cacheLimit = cacheLimit
        self.pendingLimit = pendingLimit
        self.workerLimit = workerLimit
        self.lifetime = lifetime
        self.loader = loader
    }

    func image(for request: ArtworkRequest) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        clock &+= 1
        if var entry = cache[request], entry.expiresAt > Date() {
            entry.lastUsed = clock
            cache[request] = entry
            return entry.image
        }
        cache.removeValue(forKey: request)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if jobs[request] != nil {
                    jobs[request]?.waiters[waiterID] = continuation
                    return
                }
                // Drop obsolete work rather than building a queue the size of the library.
                if pending.count == pendingLimit {
                    let oldest = pending.removeFirst()
                    if let job = jobs.removeValue(forKey: oldest) {
                        for waiter in job.waiters.values { waiter.resume(returning: nil) }
                    }
                }
                var job = Job()
                job.waiters[waiterID] = continuation
                jobs[request] = job
                pending.append(request)
                startWorkers()
            }
        } onCancel: {
            Task { await self.cancel(request, waiterID: waiterID) }
        }
    }

    func removeAll() {
        cache.removeAll()
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
                if cache.count >= cacheLimit, let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                    cache.removeValue(forKey: oldest)
                }
                clock &+= 1
                cache[request] = Entry(image: image, expiresAt: Date().addingTimeInterval(lifetime), lastUsed: clock)
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
        Statistics(cached: cache.count, pending: pending.count, active: workers.count,
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
