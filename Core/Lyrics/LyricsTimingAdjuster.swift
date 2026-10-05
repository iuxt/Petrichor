import CoreFoundation
import Darwin
import Foundation

/// Shifts the absolute timestamps in a lyric sidecar while keeping its text,
/// line endings, encoding, and relative karaoke durations intact.
enum LyricsTimingAdjuster {
    enum Failure: LocalizedError {
        case unsupportedEncoding
        case invalidTimestamp
        case noTimestamps
        case fileChanged
        case unsafeFile

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding: String(appLocalized: "This lyric file's encoding cannot be saved safely.")
            case .invalidTimestamp: String(appLocalized: "The adjustment would move a timestamp before the start of the song.")
            case .noTimestamps: String(appLocalized: "No adjustable timestamps were found in this lyric file.")
            case .fileChanged: String(appLocalized: "The lyric file changed while the adjustment was open. Reopen it and try again.")
            case .unsafeFile: String(appLocalized: "This lyric file cannot be edited safely.")
            }
        }
    }

    struct Snapshot: Sendable {
        let data: Data
        let minimumTime: TimeInterval
    }

    static func load(at fileURL: URL, source: LyricsSource, accessURL: URL?) throws -> Snapshot {
        try withAccess(fileURL: fileURL, accessURL: accessURL) {
            try checkRegularFile(fileURL)
            let data = try Data(contentsOf: fileURL)
            let decoded = try decode(data)
            let times = try timestamps(in: decoded.text, source: source)
            guard let minimum = times.min() else { throw Failure.noTimestamps }
            return Snapshot(data: data, minimumTime: minimum)
        }
    }

    static func save(_ snapshot: Snapshot, at fileURL: URL, source: LyricsSource,
                     offset: TimeInterval, accessURL: URL?) throws {
        guard offset.isFinite, offset != 0 else { return }
        try withAccess(fileURL: fileURL, accessURL: accessURL) {
            try checkRegularFile(fileURL)
            guard try Data(contentsOf: fileURL) == snapshot.data else { throw Failure.fileChanged }
            let decoded = try decode(snapshot.data)
            let adjusted = try transform(decoded.text, source: source, offset: offset)
            guard let encoded = adjusted.data(using: decoded.encoding) else { throw Failure.unsupportedEncoding }
            let output = decoded.prefix + encoded
            let directory = fileURL.deletingLastPathComponent()
            let temporary = directory.appendingPathComponent(".petrichor-lyrics-timing-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try output.write(to: temporary, options: .withoutOverwriting)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            // Recheck immediately before replacing the file so an external edit is never lost.
            try checkRegularFile(fileURL)
            guard try Data(contentsOf: fileURL) == snapshot.data else { throw Failure.fileChanged }
            let status = temporary.withUnsafeFileSystemRepresentation { source in
                fileURL.withUnsafeFileSystemRepresentation { target in rename(source!, target!) }
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    private struct Decoded {
        let text: String
        let encoding: String.Encoding
        let prefix: Data
    }

    private static func decode(_ data: Data) throws -> Decoded {
        let bomEncodings: [(bytes: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for entry in bomEncodings where data.starts(with: entry.bytes) {
            let prefix = Data(entry.bytes)
            let body = data.dropFirst(prefix.count)
            guard let text = String(data: body, encoding: entry.encoding),
                  text.data(using: entry.encoding) == body else { throw Failure.unsupportedEncoding }
            return Decoded(text: text, encoding: entry.encoding, prefix: prefix)
        }

        let names = ["GB18030", "GBK", "EUC-KR", "BIG5", "ISO-2022-JP"]
        let legacy = names.compactMap { name -> String.Encoding? in
            let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard value != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        }
        let bytes = [UInt8](data.prefix(128))
        let evenZeroes = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let oddZeroes = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let inferredUTF16: [String.Encoding] = max(evenZeroes, oddZeroes) >= bytes.count / 4
            && evenZeroes != oddZeroes
            ? [evenZeroes > oddZeroes ? .utf16BigEndian : .utf16LittleEndian] : []
        let candidates: [String.Encoding] = inferredUTF16 + [.utf8]
            + legacy + [.shiftJIS, .japaneseEUC, .isoLatin1, .windowsCP1252]
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding), text.data(using: encoding) == data {
                return Decoded(text: text, encoding: encoding, prefix: Data())
            }
        }
        throw Failure.unsupportedEncoding
    }

    private static func timestamps(in text: String, source: LyricsSource) throws -> [TimeInterval] {
        try matches(in: text, source: source).flatMap { match in
            try match.ranges.map { range in
                guard let time = parseTime((text as NSString).substring(with: range), source: source) else {
                    throw Failure.invalidTimestamp
                }
                return time
            }
        }
    }

    private struct Match {
        let ranges: [NSRange]
    }

    private static func matches(in text: String, source: LyricsSource) throws -> [Match] {
        let pattern: String
        let groups: [Int]
        switch source {
        case .lrc:
            pattern = "(\\[|<)(\\d+:\\d+(?:\\.\\d+)?)(\\]|>)"
            groups = [2]
        case .srt:
            pattern = "(?m)^\\s*(\\d{2}:\\d{2}:\\d{2},\\d{3})\\s*-->\\s*(\\d{2}:\\d{2}:\\d{2},\\d{3})\\s*$"
            groups = [1, 2]
        case .ksc:
            pattern = "(?im)^\\s*karaoke\\.add\\s*\\(\\s*'([^']+)'\\s*,\\s*'([^']+)'"
            groups = [1, 2]
        case .ttml:
            pattern = "(?i)\\b(?:begin|end)\\s*=\\s*([\"'])([^\"']+)\\1"
            groups = [2]
        case .embedded, .none:
            throw Failure.noTimestamps
        }
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            if source == .lrc {
                let ns = text as NSString
                let opening = ns.substring(with: match.range(at: 1))
                let closing = ns.substring(with: match.range(at: 3))
                guard (opening == "[" && closing == "]") || (opening == "<" && closing == ">") else { return nil }
            }
            return Match(ranges: groups.map { match.range(at: $0) })
        }
    }

    private static func transform(_ text: String, source: LyricsSource, offset: TimeInterval) throws -> String {
        let matches = try matches(in: text, source: source)
        guard !matches.isEmpty else { throw Failure.noTimestamps }
        let original = text as NSString
        let output = NSMutableString(string: text)
        for range in matches.flatMap(\.ranges).reversed() {
            let raw = original.substring(with: range)
            guard let time = parseTime(raw, source: source), time + offset >= -0.000_001 else {
                throw Failure.invalidTimestamp
            }
            output.replaceCharacters(in: range, with: formatTime(max(0, time + offset), like: raw, source: source))
        }
        return output as String
    }

    private static func parseTime(_ raw: String, source: LyricsSource) -> TimeInterval? {
        if source == .ttml {
            if raw.hasSuffix("ms"), let value = Double(raw.dropLast(2)) { return value / 1000 }
            if raw.hasSuffix("s"), let value = Double(raw.dropLast()) { return value }
            if !raw.contains(":"), let value = Double(raw), value.isFinite, value >= 0 { return value }
        }
        let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!),
              seconds >= 0, seconds < 60 else { return nil }
        let leading = parts.dropLast().compactMap(Double.init)
        guard leading.count == parts.count - 1, leading.allSatisfy({ $0 >= 0 }),
              parts.count != 3 || leading[1] < 60 else { return nil }
        let result = parts.count == 2 ? leading[0] * 60 + seconds
            : leading[0] * 3600 + leading[1] * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func formatTime(_ value: TimeInterval, like raw: String, source: LyricsSource) -> String {
        let fractionDigits = max(3, min(6, raw.split(separator: raw.contains(",") ? "," : ".").dropFirst().first?.count ?? 0))
        if source == .ttml, raw.hasSuffix("ms") {
            return String(format: "%.3fms", locale: Locale(identifier: "en_US_POSIX"), value * 1000)
        }
        if source == .ttml, raw.hasSuffix("s") {
            return String(format: "%.*fs", locale: Locale(identifier: "en_US_POSIX"), fractionDigits, value)
        }
        if source == .ttml, !raw.contains(":"), let _ = Double(raw) {
            return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), fractionDigits, value)
        }
        let scale = Int64(pow(10, Double(fractionDigits)))
        let ticks = Int64((value * Double(scale)).rounded())
        let wholeSeconds = ticks / scale
        let hours = Int(wholeSeconds / 3600)
        let usesHours = source == .srt || raw.filter({ $0 == ":" }).count == 2
        let minutes = usesHours ? Int(wholeSeconds / 60) % 60 : Int(wholeSeconds / 60)
        let seconds = Int(wholeSeconds % 60)
        let fraction = String(ticks % scale)
        let paddedFraction = String(repeating: "0", count: fractionDigits - fraction.count) + fraction
        let separator = source == .srt ? "," : "."
        let secondText = String(format: "%02d", seconds) + separator + paddedFraction
        if usesHours {
            return String(format: "%02d:%02d:%@", hours, minutes, secondText)
        }
        return String(format: "%02d:%@", minutes, secondText)
    }

    private static func checkRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unsafeFile }
    }

    private static func withAccess<T>(fileURL: URL, accessURL: URL?, _ body: () throws -> T) throws -> T {
        let folderScope = accessURL?.startAccessingSecurityScopedResource() ?? false
        let fileScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if fileScope { fileURL.stopAccessingSecurityScopedResource() }
            if folderScope { accessURL?.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }
}
