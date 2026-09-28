import Foundation

final class ArtworkFileCache {
    static let shared = ArtworkFileCache()

    private let fileManager: FileManager
    private let rootURL: URL
    private let imagesURL: URL
    private let maxBytes: Int64
    private let queue = DispatchQueue(label: "org.petrichor.artwork-file-cache", qos: .utility)
    // Access only on queue. Enumerate once, then account for individual writes;
    // scanning every cached file on each new thumbnail makes scrolling O(n²).
    private var knownBytes: Int64?

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        maxBytes: Int64 = 512 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes

        let baseURL: URL
        if let rootURL {
            baseURL = rootURL
        } else {
            let appSupport = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? About.bundleIdentifier
            baseURL = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        }

        self.rootURL = baseURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        self.imagesURL = self.rootURL.appendingPathComponent("images", isDirectory: true)
    }

    func data(for key: ArtworkCacheKey) -> Data? {
        queue.sync {
            let url = fileURL(for: key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            touch(url)
            return data
        }
    }

    func store(_ data: Data, for key: ArtworkCacheKey) {
        queue.async {
            do {
                try self.ensureDirectories()
                if self.knownBytes == nil {
                    self.knownBytes = self.cacheFiles().reduce(Int64(0)) { $0 + $1.size }
                }
                let url = self.fileURL(for: key)
                let oldSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try data.write(to: url, options: .atomic)
                let total = (self.knownBytes ?? 0) - Int64(oldSize) + Int64(data.count)
                self.knownBytes = total
                if total > self.maxBytes {
                    self.trimToLimitLocked()
                }
            } catch {
                self.knownBytes = nil
                Logger.error("Failed to write artwork cache file: \(error)")
            }
        }
    }

    func trimToLimit() {
        queue.async {
            self.trimToLimitLocked()
        }
    }

    func clear() {
        queue.async {
            do {
                if self.fileManager.fileExists(atPath: self.rootURL.path) {
                    try self.fileManager.removeItem(at: self.rootURL)
                }
                self.knownBytes = 0
            } catch {
                self.knownBytes = nil
                Logger.error("Failed to clear artwork cache: \(error)")
            }
        }
    }

    func cacheSize() -> Int64 {
        queue.sync {
            let total = self.cacheFiles().reduce(Int64(0)) { $0 + $1.size }
            self.knownBytes = total
            return total
        }
    }

    private func fileURL(for key: ArtworkCacheKey) -> URL {
        imagesURL.appendingPathComponent(key.filename, isDirectory: false)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimToLimitLocked() {
        let files = cacheFiles()
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        knownBytes = total
        guard total > maxBytes else { return }

        let targetBytes = maxBytes * 9 / 10
        var remaining = total
        for file in files.sorted(by: { $0.lastAccess < $1.lastAccess }) {
            guard remaining > targetBytes else { break }
            do {
                try fileManager.removeItem(at: file.url)
                remaining -= file.size
            } catch {
                Logger.error("Failed to remove artwork cache file \(file.url.lastPathComponent): \(error)")
            }
        }
        knownBytes = remaining
    }

    private struct CacheFile {
        let url: URL
        let size: Int64
        let lastAccess: Date
    }

    private func cacheFiles() -> [CacheFile] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "heic",
                  let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else { return nil }
            return CacheFile(
                url: url,
                size: Int64(values.fileSize ?? 0),
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
    }
}
