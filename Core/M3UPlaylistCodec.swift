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

        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            break
        }

        if normalized.hasPrefix("//") {
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }

        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        normalized = normalized.removingPercentEncoding ?? normalized

        var result: [String] = []
        func appendUnique(_ path: String) {
            if !result.contains(path) {
                result.append(path)
            }
        }

        if normalized.hasPrefix("/") {
            appendUnique(URL(fileURLWithPath: normalized).standardizedFileURL.path)
            if normalized.hasPrefix("/Volumes/") {
                appendUnique(String(normalized.dropFirst(8)))
            } else if !normalized.hasPrefix("/Users/") {
                appendUnique("/Volumes" + normalized)
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

    static func relativeOrAbsolutePath(for trackURL: URL, musicFolder: URL) -> String {
        let root = musicFolder.standardizedFileURL.path
        let path = trackURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"

        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }

        return path
    }

    static func render(trackURLs: [URL], musicFolder: URL) -> String {
        var lines = [header]

        for url in trackURLs {
            lines.append(relativeOrAbsolutePath(for: url, musicFolder: musicFolder))
        }

        return lines.joined(separator: lineEnding) + lineEnding
    }
}
