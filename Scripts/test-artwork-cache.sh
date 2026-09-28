#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'struct ArtworkCacheKey|enum ArtworkKind|struct ArtworkRequest' Core/Artwork/ArtworkRequest.swift >/dev/null; then
    printf 'Artwork request/key types are missing.\n' >&2
    exit 1
fi

if ! rg -n 'final class ArtworkFileCache|func data\(for key: ArtworkCacheKey\)|func store\(_ data: Data, for key: ArtworkCacheKey\)|func trimToLimit\(\)|func clear\(\)' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'ArtworkFileCache API is incomplete.\n' >&2
    exit 1
fi

if ! rg -n 'maxBytes: Int64 = 512 \* 1024 \* 1024' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache must default to 512 MB.\n' >&2
    exit 1
fi

if ! rg -n 'targetBytes = maxBytes \* 9 / 10|sorted\(by: \{.*lastAccess' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache trim must delete least-recently-used files down to 90%% of limit.\n' >&2
    exit 1
fi

swift - <<'SWIFT'
import CryptoKit
import Foundation

enum ArtworkKind: String { case track, album, playlistDerived = "playlist-derived" }

struct ArtworkCacheKey: Hashable {
    let kind: ArtworkKind
    let identity: String
    let sourcePath: String
    let sourceSize: Int64
    let sourceModifiedAt: TimeInterval
    let version: Int

    var filename: String {
        let raw = [
            kind.rawValue,
            identity,
            sourcePath,
            String(sourceSize),
            String(sourceModifiedAt),
            String(version)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }
}

let a = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 10, sourceModifiedAt: 1, version: 1)
let b = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 11, sourceModifiedAt: 1, version: 1)
if a.filename == b.filename {
    fatalError("cache key must change when source size changes")
}
if !a.filename.hasSuffix(".heic") {
    fatalError("cache key filename must use compressed artwork extension")
}
SWIFT

# Exercise production code: cancellation lifetime and disk-cache scaling.
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/ArtworkRegression.swift" <<'SWIFT'
import AppKit
import Foundation

enum About { static let bundleIdentifier = "artwork-regression" }
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

// Simulate a backend that cannot interrupt an in-progress file read.
actor MetadataProbe {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func read() async -> Data? {
        MetadataEngine.started.increment()
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return Data([1, 2, 3])
    }
    func finishReads() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
enum MetadataEngine {
    static let started = Counter()
    static let probe = MetadataProbe()
    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        await probe.read()
    }
    static func extractRawEmbeddedArtwork(from url: URL) async -> Data? {
        await probe.read()
    }
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

@main struct ArtworkRegression {
    static func waitUntil(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError(message)
    }

    static func main() async {
        let queue = OperationQueue()
        queue.isSuspended = true
        let completed = Counter()
        let rendered = Counter()
        let tasks = (0..<200).map { _ in
            Task.detached {
                let image = await queue.renderArtwork {
                    rendered.increment()
                    return NSImage(size: NSSize(width: 1, height: 1))
                }
                precondition(image == nil)
                completed.increment()
            }
        }
        await waitUntil("renders were not queued") { queue.operationCount == tasks.count }
        tasks.forEach { $0.cancel() }
        await waitUntil("cancelled queued renders leaked their waiters") { completed.value == tasks.count }
        precondition(rendered.value == 0)
        queue.isSuspended = false

        // Cancellation before continuation installation must also finish.
        let cancelled = ArtworkLoadOperation { fatalError("cancelled operation ran") }
        cancelled.cancel()
        let earlyResult = await withCheckedContinuation { cancelled.install($0) }
        precondition(earlyResult == nil)

        // Cancellation during rendering races completion, but resumes only once.
        let started = Counter()
        let runningCompleted = Counter()
        let release = DispatchSemaphore(value: 0)
        let running = Task.detached {
            let image = await queue.renderArtwork {
                started.increment()
                release.wait()
                return NSImage(size: NSSize(width: 1, height: 1))
            }
            precondition(image == nil)
            runningCompleted.increment()
        }
        await waitUntil("render did not start") { started.value == 1 }
        running.cancel()
        await waitUntil("running cancellation did not finish") { runningCompleted.value == 1 }
        release.signal()
        await waitUntil("cancelled operations did not drain") { queue.operationCount == 0 }
        let normal = await queue.renderArtwork { NSImage(size: NSSize(width: 1, height: 1)) }
        precondition(normal != nil)

        testFileCache()
        await testResolverLoadLimit()
        testDownsampling()
        print("Artwork cancellation, bounded loading, downsampling and cache scaling regressions passed")
    }

    static func testResolverLoadLimit() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ArtworkFileCache(rootURL: root)
        let resolver = ArtworkResolver(cache: cache)
        var requests: [ArtworkRequest] = []
        for index in 0..<204 {
            let url = root.appendingPathComponent("song-\(index).mp3")
            try! Data([0]).write(to: url)
            requests.append(.track(url))
        }
        let finished = Counter()
        let active = requests.prefix(2).map { request in
            Task.detached {
                _ = await resolver.artworkData(for: request)
                finished.increment()
            }
        }
        await waitUntil("two metadata reads did not start") { MetadataEngine.started.value == 2 }
        let waitingFinished = Counter()
        let waiting = requests.dropFirst(2).dropLast(2).map { request in
            Task.detached {
                let data = await resolver.artworkData(for: request)
                precondition(data == nil)
                waitingFinished.increment()
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(MetadataEngine.started.value == 2, "full-resolution reads exceeded the concurrency limit")
        waiting.forEach { $0.cancel() }
        await waitUntil("cancelled read waiters did not drain") { waitingFinished.value == waiting.count }
        active.forEach { $0.cancel() }
        let next = Task.detached { await resolver.artworkData(for: requests[202]) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(MetadataEngine.started.value == 2, "cancellation released a permit while decoding was still active")
        precondition(finished.value == 0)
        await MetadataEngine.probe.finishReads()
        for task in active { await task.value }
        let nextData = await next.value
        precondition(nextData != nil)
        precondition(MetadataEngine.started.value == 3)
        // Force disk writes to finish before removing the test directory.
        _ = cache.cacheSize()
        let lastData = await resolver.artworkData(for: requests[203])
        precondition(lastData != nil, "permits leaked after cancellation")
        _ = cache.cacheSize()
    }

    static func testDownsampling() {
        autoreleasepool {
            let context = CGContext(data: nil, width: 1200, height: 600,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
            let data = ImageUtils.encodeJPEG(context.makeImage()!, quality: 0.8)!
            let thumbnail = ImageUtils.downsampledImage(from: data, maxDimension: 80)!
            precondition(thumbnail.width == 80 && thumbnail.height == 40)
            let compressed = ImageUtils.compressImage(from: data)!
            let artwork = ImageUtils.downsampledImage(from: compressed, maxDimension: 1200)!
            precondition(artwork.width == 960 && artwork.height == 480, "must not upscale")
            precondition(ImageUtils.downsampledImage(from: Data([1, 2]), maxDimension: 80) == nil)
            precondition(ImageUtils.downsampledImage(from: data, maxDimension: 0) == nil)
        }
    }

    static func key(_ index: Int) -> ArtworkCacheKey {
        ArtworkCacheKey(kind: .track, identity: "track-\(index)",
            source: ArtworkSourceIdentity(path: "/track-\(index).mp3", size: 1, modifiedAt: 1), version: 1)
    }

    static func testFileCache() {
        let manager = CountingFileManager()
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let cache = ArtworkFileCache(fileManager: manager, rootURL: root, maxBytes: 100_000)
        let bytes = Data(repeating: 1, count: 100)
        for index in 0..<400 { cache.store(bytes, for: key(index)) }
        // A read flushes all queued writes without enumerating the directory.
        precondition(cache.data(for: key(399)) == bytes)
        precondition(manager.listings.value == 1, "each store must not rescan the growing cache")
        precondition(cache.cacheSize() == 40_000)
        cache.store(Data(repeating: 2, count: 200), for: key(0))
        precondition(cache.cacheSize() == 40_100, "replacement must subtract the previous file size")

        // Reopen an existing cache and verify initial accounting and LRU eviction.
        let reopened = ArtworkFileCache(fileManager: manager, rootURL: root, maxBytes: 40_150)
        let images = root.appendingPathComponent("ArtworkCache/images")
        for index in 0..<400 {
            try! manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: images.appendingPathComponent(key(index).filename).path)
        }
        reopened.store(bytes, for: key(400))
        let size = reopened.cacheSize()
        precondition(size <= 40_150 * 9 / 10)
        precondition(reopened.data(for: key(0)) == nil, "oldest entry must be evicted first")
        precondition(reopened.data(for: key(400)) == bytes)
        reopened.clear()
        precondition(reopened.cacheSize() == 0)
        reopened.store(bytes, for: key(401))
        precondition(reopened.cacheSize() == 100)
    }
}
SWIFT
swiftc -parse-as-library Utilities/ArtworkCache.swift Core/Artwork/ArtworkRequest.swift \
    Core/Artwork/ArtworkFileCache.swift Core/Artwork/ArtworkLoadLimiter.swift Core/Artwork/TrackThumbnailCache.swift \
    Core/Artwork/ArtworkResolver.swift Core/Metadata/ExternalArtworkResolver.swift Utilities/ImageUtils.swift \
    "$test_dir/ArtworkRegression.swift" -o "$test_dir/artwork-regression"
"$test_dir/artwork-regression"
