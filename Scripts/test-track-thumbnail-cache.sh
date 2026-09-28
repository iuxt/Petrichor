#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/Regression.swift" <<'SWIFT'
import AppKit
import Foundation

enum About { static let bundleIdentifier = "thumbnail-regression" }
enum Logger {
    static func error(_ message: String) { fatalError(message) }
    static func warning(_ message: String) { print(message) }
}
enum AlbumArtFormat {
    static let maxArtworkSize = 20 * 1024 * 1024
    static let maxArtworkPixelDimension = 8000
    static let supportedExtensions = ["jpg", "png"]
    static let knownFilenames = ["cover"]
    static func isSupported(_ ext: String) -> Bool { supportedExtensions.contains(ext.lowercased()) }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
final class CountingFileManager: FileManager, @unchecked Sendable {
    let listings = Counter()
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        listings.increment()
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
enum MetadataEngine {
    static let rawReads = Counter()
    static let largeReads = Counter()
    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        largeReads.increment()
        return nil
    }
    static func extractRawEmbeddedArtwork(from url: URL) async -> Data? {
        rawReads.increment()
        if url.lastPathComponent == "embedded.mp3" { return try? Data(contentsOf: url) }
        return nil
    }
}
actor Gate {
    let entered = Counter()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func load() async -> NSImage? {
        entered.increment()
        if !open { await withCheckedContinuation { waiters.append($0) } }
        return NSImage(size: NSSize(width: 80, height: 80))
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
actor OrderedGate {
    var entered: [ArtworkRequest] = []
    private var waiters: [ArtworkRequest: CheckedContinuation<NSImage?, Never>] = [:]
    func load(_ request: ArtworkRequest) async -> NSImage? {
        entered.append(request)
        return await withCheckedContinuation { waiters[request] = $0 }
    }
    func release(_ request: ArtworkRequest) {
        waiters.removeValue(forKey: request)?.resume(returning: NSImage(size: NSSize(width: 80, height: 80)))
    }
}
@main struct Regression {
    static func request(_ index: Int) -> ArtworkRequest {
        .thumbnail(URL(fileURLWithPath: "/music/\(index).mp3"), albumTitle: "Album")
    }
    static func wait(_ condition: () async -> Bool) async {
        for _ in 0..<5000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for cache state")
    }
    static func main() async throws {
        await deduplication()
        await boundedQueue()
        await cachedMissesAndEviction()
        await warmCacheBypassesDelay()
        await visibleLoadsPrecedePrefetch()
        await synchronousLRU()
        try await libraryStress()
        print("Track thumbnail regressions passed")
    }
    static func visibleLoadsPrecedePrefetch() async {
        let gate = OrderedGate()
        let cache = TrackThumbnailCache(pendingLimit: 3, workerLimit: 1, loader: { await gate.load($0) })
        let first = Task { await cache.image(for: request(0), prefetch: true) }
        await wait { await gate.entered.count == 1 }
        let offscreen = Task { await cache.image(for: request(1), prefetch: true) }
        await wait { await cache.statistics.pending == 1 }
        let promoted = Task { await cache.image(for: request(2), prefetch: true) }
        await wait { await cache.statistics.pending == 2 }
        let visible = Task { await cache.image(for: request(3)) }
        await wait { await cache.statistics.pending == 3 }
        let overflow = await cache.image(for: request(4), prefetch: true)
        let full = await cache.statistics
        precondition(overflow == nil && full.pending == 3 && full.waiters == 4,
                     "prefetch overflow must not displace queued visible work")
        await gate.release(request(0))
        _ = await first.value
        await wait { await gate.entered.count == 2 }
        let order = await gate.entered
        precondition(order == [request(0), request(3)], "visible artwork must precede queued prefetch")
        let joined = Task { await cache.image(for: request(2)) }
        await wait { await cache.statistics.waiters == 4 }
        await gate.release(request(3))
        _ = await visible.value
        await wait { await gate.entered.count == 3 }
        let promotedOrder = await gate.entered
        precondition(promotedOrder.last == request(2), "a row entering the viewport must promote its existing prefetch")
        offscreen.cancel()
        _ = await offscreen.value
        await gate.release(request(2))
        let prefetchedImage = await promoted.value
        let joinedImage = await joined.value
        precondition(prefetchedImage === joinedImage, "prefetch and visible rows must share one decoded image")
        let state = await cache.statistics
        precondition(state.active == 0 && state.pending == 0 && state.waiters == 0)
    }
    static func synchronousLRU() async {
        let cache = TrackThumbnailCache(cacheLimit: 7, loader: { request in
            request == Self.request(99) ? nil : NSImage(size: NSSize(width: 80, height: 80))
        })
        var order: [Int] = []
        // Compare the linked LRU against a simple reference, including synchronous touches.
        for step in 0..<300 {
            let index = (step * 17 + step / 9) % 13
            if let cached = cache.cachedImage(for: request(index)) {
                precondition(cached.image != nil && order.contains(index))
            } else {
                precondition(!order.contains(index))
                _ = await cache.image(for: request(index))
            }
            order.removeAll { $0 == index }
            order.append(index)
            if order.count > 7 { order.removeFirst() }
            let state = await cache.statistics
            precondition(state.cached == order.count)
        }
        _ = await cache.image(for: request(99))
        let miss = cache.cachedImage(for: request(99))
        precondition(miss != nil && miss?.image == nil, "synchronous lookup must distinguish a cached miss")
        await cache.removeAll()
        precondition(cache.cachedImage(for: request(99)) == nil, "clear must invalidate synchronous reads too")
        let original = await cache.image(for: request(0))
        precondition(cache.cachedImage(for: request(0))?.image === original, "synchronous hits must return the decoded object")
    }
    static func deduplication() async {
        let gate = Gate()
        let cache = TrackThumbnailCache(loader: { _ in await gate.load() })
        let first = Task { await cache.image(for: request(0)) }
        let second = Task { await cache.image(for: request(0)) }
        await wait { await cache.statistics.waiters == 2 }
        first.cancel()
        let cancelled = await first.value
        precondition(cancelled == nil)
        await gate.release()
        let result = await second.value
        precondition(result != nil && gate.entered.value == 1, "duplicate loads must share one worker")
        let cached = await cache.image(for: request(0))
        precondition(cached === result)
        await cache.removeAll()
        _ = await cache.image(for: request(0))
        precondition(gate.entered.value == 2, "clear must invalidate memory results")
    }
    static func boundedQueue() async {
        let gate = Gate()
        let cache = TrackThumbnailCache(loader: { _ in await gate.load() })
        let submitted = Counter()
        let completed = Counter()
        let tasks = (0..<4000).map { index in
            Task.detached {
                submitted.increment()
                _ = await cache.image(for: request(index))
                completed.increment()
            }
        }
        await wait { submitted.value == 4000 && completed.value >= 3934 }
        let full = await cache.statistics
        precondition(full.active == 2 && full.pending <= 64 && full.waiters <= 66)
        tasks.forEach { $0.cancel() }
        await wait { completed.value == 4000 }
        let cancelled = await cache.statistics
        precondition(cancelled.pending == 0 && cancelled.waiters == 0)
        precondition(cancelled.active == 2, "in-progress reads retain their worker slot until they finish")
        await gate.release()
        await wait { await cache.statistics.active == 0 }
        let drained = await cache.statistics
        precondition(drained.cached == 0, "cancelled work must not cache misses")
        let image = await cache.image(for: request(5000))
        precondition(image != nil, "queue must recover after mass cancellation")
    }
    static func cachedMissesAndEviction() async {
        let misses = Counter()
        let missing = TrackThumbnailCache(missLifetime: 0.02, loader: { _ in misses.increment(); return nil })
        _ = await missing.image(for: request(0))
        _ = await missing.image(for: request(0))
        precondition(misses.value == 1, "missing artwork must be cached")
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = await missing.image(for: request(0))
        precondition(misses.value == 2, "missing artwork must be retried after expiry")
        let reads = Counter()
        let cache = TrackThumbnailCache(cacheLimit: 2, loader: { _ in
            reads.increment()
            return NSImage(size: NSSize(width: 80, height: 80))
        })
        for index in [0, 1, 0, 2, 0] { _ = await cache.image(for: request(index)) }
        precondition(reads.value == 3)
        _ = await cache.image(for: request(1))
        let state = await cache.statistics
        precondition(reads.value == 4 && state.cached == 2, "cache must evict the least recently used result")
    }
    static func warmCacheBypassesDelay() async {
        let reads = Counter()
        let cache = TrackThumbnailCache(missLifetime: 0.02, loader: { request in
            reads.increment()
            return request == Self.request(0) ? NSImage(size: NSSize(width: 80, height: 80)) : nil
        })
        let original = await cache.image(for: request(0))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let start = Date()
        let cached = await cache.image(for: request(0), delayIfMissing: 2_000_000_000)
        precondition(cached === original && reads.value == 1, "decoded thumbnails must not expire with misses")
        precondition(Date().timeIntervalSince(start) < 1, "warm thumbnails must bypass scroll debounce")
        _ = await cache.image(for: request(1))
        let missStart = Date()
        _ = await cache.image(for: request(1), delayIfMissing: 2_000_000_000)
        precondition(reads.value == 2 && Date().timeIntervalSince(missStart) < 1,
                     "cached missing artwork must also bypass scroll debounce")
        let delayed = Task { await cache.image(for: request(2), delayIfMissing: 2_000_000_000) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        delayed.cancel()
        let cancelled = await delayed.value
        precondition(cancelled == nil && reads.value == 2, "recycled rows must cancel before reading artwork")
        await cache.removeAll()
        let state = await cache.statistics
        precondition(state.cached == 0, "explicit invalidation must release persistent thumbnails")
    }
    static func libraryStress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let raw = autoreleasepool { () -> Data in
            let context = CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
            return ImageUtils.encodeJPEG(context.makeImage()!)!
        }
        try raw.write(to: music.appendingPathComponent("cover.jpg"))
        var requests: [ArtworkRequest] = []
        for index in 0..<4000 {
            let url = music.appendingPathComponent("\(index).mp3")
            try Data([0]).write(to: url)
            requests.append(.thumbnail(url, albumTitle: "Album"))
        }
        let manager = CountingFileManager()
        let disk = ArtworkFileCache(rootURL: root)
        let resolver = ArtworkResolver(cache: disk, fileManager: manager)
        let loads = Counter()
        let thumbnails = TrackThumbnailCache(loader: { request in
            loads.increment()
            guard let data = await resolver.artworkData(for: request) else { return nil }
            return autoreleasepool {
                guard let image = ImageUtils.downsampledImage(from: data, maxDimension: 80) else { return nil }
                precondition(image.width == 80 && image.height == 40)
                return NSImage(cgImage: image, size: NSSize(width: 80, height: 40))
            }
        })
        let start = Date()
        for pass in 0..<2 {
            for request in requests { _ = await thumbnails.image(for: request) }
            let state = await thumbnails.statistics
            precondition(state.cached == 4000 && state.active == 0 && state.pending == 0 && state.waiters == 0)
            precondition(loads.value == 4000, "repeat scrolling must reuse decoded thumbnails without disk reads or decoding")
            print("4,000-track pass \(pass + 1): entries=\(state.cached), pending=\(state.pending), thumbnail loads=\(loads.value), metadata reads=\(MetadataEngine.rawReads.value)")
        }
        precondition(MetadataEngine.largeReads.value == 0, "list requests must bypass full artwork compression")
        precondition(MetadataEngine.rawReads.value == 4000, "second pass must reuse missing-embedded results")
        precondition(manager.listings.value < 10, "must not enumerate a 4,000-track directory for every row")
        _ = disk.cacheSize() // flush pending disk writes
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ArtworkCache/images").path)
        precondition(files.count == 1 && files[0].hasSuffix(".jpg"), "shared folder artwork must have one thumbnail file")
        // A new audio file with embedded artwork must still take the raw-picture path.
        let embedded = music.appendingPathComponent("embedded.mp3")
        try raw.write(to: embedded)
        let small = await resolver.artworkData(for: .thumbnail(embedded, albumTitle: "Album"))
        let image = ImageUtils.downsampledImage(from: small!, maxDimension: 2400)!
        precondition(image.width == 80 && image.height == 40)
        precondition(MetadataEngine.largeReads.value == 0)
        // A changed audio source invalidates a cached missing-embedded result.
        try Data([0, 1]).write(to: requests[0].audioURL)
        _ = await resolver.artworkData(for: requests[0])
        precondition(MetadataEngine.rawReads.value == 4002)
        _ = disk.cacheSize()
        print("8,000 thumbnail requests: \(Date().timeIntervalSince(start))s; folder listings=\(manager.listings.value); disk files=\(files.count)")
    }
}
SWIFT
swiftc -g -parse-as-library Core/Artwork/ArtworkRequest.swift Core/Artwork/ArtworkFileCache.swift \
    Core/Artwork/ArtworkLoadLimiter.swift Core/Artwork/ArtworkResolver.swift Core/Artwork/TrackThumbnailCache.swift \
    Core/Metadata/ExternalArtworkResolver.swift Utilities/ImageUtils.swift "$test_dir/Regression.swift" -o "$test_dir/regression"
"$test_dir/regression"
