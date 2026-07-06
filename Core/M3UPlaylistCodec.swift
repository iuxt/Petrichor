import Foundation

enum M3UPlaylistCodec {
    static let supportedExtensions: Set<String> = ["m3u", "m3u8"]
    private static let header = "#EXTM3U"
    private static let commentPrefix = "#"
    private static let lineEnding = "\r\n"

    static func playlistDirectory(in musicFolder: URL) -> URL {
        musicFolder.appendingPathComponent("playlists", isDirectory: true)
    }

    static func playlistFiles(in musicFolder: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = playlistDirectory(in: musicFolder)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func parseTrackEntries(from content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(commentPrefix) }
    }

    static func readText(from url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    static func pathVariations(for entry: String, musicFolder: URL, playlistFileURL: URL) -> [String] {
        var normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip URL schemes. Percent-decoding only applies to scheme-bearing entries:
        // bare relative/absolute paths are file paths and may legitimately contain
        // a literal `%` character, which unconditional decoding would corrupt.
        var wasSchemeEntry = false
        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            wasSchemeEntry = true
            break
        }

        if normalized.hasPrefix("//") {
            // UNC/SMB-style share path: map to a /Volumes mount point.
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }

        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        if wasSchemeEntry {
            normalized = normalized.removingPercentEncoding ?? normalized
        }

        var result: [String] = []
        func appendUnique(_ path: String) {
            if !result.contains(path) {
                result.append(path)
            }
        }

        if normalized.hasPrefix("/") {
            appendUnique(URL(fileURLWithPath: normalized).standardizedFileURL.path)
            // Only emit the cross-form (drop or add `/Volumes`) variant for entries that
            // came in as a UNC/SMB share — a bare local path like /tmp/x.flac must not be
            // rewritten into /Volumes/tmp/x.flac, which could silently bind the wrong track.
            if normalized.hasPrefix("/Volumes/") {
                appendUnique(String(normalized.dropFirst(8)))
            }
        } else {
            var relativePath = normalized
            while relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            appendUnique(musicFolder.appendingPathComponent(relativePath).standardizedFileURL.path)
            appendUnique(playlistFileURL.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL.path)
            appendUnique(relativePath)
        }

        return result
    }

    /// Render a single track's path for an M3U file.
    ///
    /// Writes a path *relative to the playlist file's own directory* when the track
    /// lives inside the music folder (so the file is portable to other players, which
    /// resolve entries relative to the `.m3u` location). Falls back to an absolute
    /// path for tracks outside the playlist's directory, where no safe relative form
    /// exists.
    static func relativeOrAbsolutePath(for trackURL: URL, musicFolder: URL, playlistFileURL: URL) -> String {
        let track = trackURL.standardizedFileURL
        let playlistDir = playlistFileURL.standardizedFileURL.deletingLastPathComponent()

        if let relative = relativePath(from: playlistDir, to: track) {
            return relative
        }

        // Track is not under the playlist's directory: emit an absolute path so the
        // entry remains unambiguous and resolvable.
        return track.path
    }

    /// Returns a POSIX relative path from `base` to `target`, including `..` segments
    /// when `target` lives outside `base`'s subtree. Returns nil only when the result
    /// would be empty. Both URLs must be standardized file URLs.
    private static func relativePath(from base: URL, to target: URL) -> String? {
        // pathComponents includes a leading "/" for absolute URLs; drop it so we
        // compare the logical path segments.
        var baseComponents = base.pathComponents
        var targetComponents = target.pathComponents
        if baseComponents.first == "/" { baseComponents.removeFirst() }
        if targetComponents.first == "/" { targetComponents.removeFirst() }

        // Strip the common prefix.
        var commonCount = 0
        while commonCount < baseComponents.count,
              commonCount < targetComponents.count,
              baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }

        // One ".." for each remaining base component not shared with the target.
        let upCount = baseComponents.count - commonCount
        let downComponents = Array(targetComponents.dropFirst(commonCount))

        var pieces = [String](repeating: "..", count: upCount)
        pieces.append(contentsOf: downComponents)

        let relative = pieces.joined(separator: "/")
        return relative.isEmpty ? nil : relative
    }

    static func render(trackURLs: [URL], musicFolder: URL, playlistFileURL: URL) -> String {
        var lines = [header]

        for url in trackURLs {
            lines.append(relativeOrAbsolutePath(for: url, musicFolder: musicFolder, playlistFileURL: playlistFileURL))
        }

        return lines.joined(separator: lineEnding) + lineEnding
    }
}
