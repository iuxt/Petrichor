import Foundation
import CoreFoundation

/// A virtual track keeps its own library identity while all file IO uses sourceURL.
struct CueTrackSegment: Codable, Equatable, Hashable, Sendable {
    var sheetPath: String
    var sourcePath: String
    var number: Int
    var start: Double
    var end: Double
    var albumSourcePath: String? = nil

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var albumSourceURL: URL { albumSourcePath.map { URL(fileURLWithPath: $0) } ?? sourceURL }
    var sheetURL: URL { URL(fileURLWithPath: sheetPath) }
    var duration: Double { end - start }
    var libraryPath: String { Self.libraryPath(sheetURL: sheetURL, number: number) }

    static func libraryPath(sheetURL: URL, number: Int) -> String {
        sheetURL.standardizedFileURL.path + "#track-\(number)"
    }

    var json: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String?) -> Self? {
        guard let data = json?.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.start.isFinite, value.end.isFinite,
              value.start >= 0, value.end > value.start else { return nil }
        return value
    }
}

struct CueSheet {
    struct Entry {
        var number: Int
        var file: String
        var title: String?
        var performer: String?
        var songwriter: String?
        var start: Double?
    }

    var title: String?
    var performer: String?
    var songwriter: String?
    var genre: String?
    var year: String?
    var discNumber: Int?
    var entries: [Entry] = []

    enum ParseError: Error { case invalidSheet, unsupportedEncoding }

    /// Decode common ripper encodings without silently replacing non-ASCII titles.
    static func read(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        let legacyEncodings = [
            CFStringEncodings.GB_18030_2000.rawValue,
            CFStringEncodings.big5.rawValue,
            CFStringEncodings.shiftJIS.rawValue
        ].map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0))) }
        var encodings: [String.Encoding] = [.utf8]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            encodings.insert(.utf16, at: 0)
        }
        encodings += legacyEncodings + [.windowsCP1252]
        for encoding in encodings {
            if let content = String(data: data, encoding: encoding) {
                return try parse(content)
            }
        }
        throw ParseError.unsupportedEncoding
    }

    static func parse(_ content: String) throws -> Self {
        var sheet = Self()
        var currentFile: String?
        var currentEntry: Entry?
        var inTrack = false
        var numbers = Set<Int>()

        func finishEntry() throws {
            if let entry = currentEntry {
                guard entry.start != nil, numbers.insert(entry.number).inserted else {
                    throw ParseError.invalidSheet
                }
                sheet.entries.append(entry)
            }
            currentEntry = nil
        }

        for line in content.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            var rest = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = token(&rest).uppercased()
            switch command {
            case "FILE":
                try finishEntry()
                inTrack = false
                let file = token(&rest)
                guard !file.isEmpty else { throw ParseError.invalidSheet }
                currentFile = file
            case "TRACK":
                try finishEntry()
                inTrack = true
                let number = Int(token(&rest))
                let type = token(&rest).uppercased()
                guard let number, (1...99).contains(number), let file = currentFile else {
                    throw ParseError.invalidSheet
                }
                if type == "AUDIO" { currentEntry = Entry(number: number, file: file) }
            case "TITLE", "PERFORMER", "SONGWRITER":
                let value = textValue(rest)
                if inTrack {
                    if command == "TITLE" { currentEntry?.title = value }
                    if command == "PERFORMER" { currentEntry?.performer = value }
                    if command == "SONGWRITER" { currentEntry?.songwriter = value }
                } else {
                    if command == "TITLE" { sheet.title = value }
                    if command == "PERFORMER" { sheet.performer = value }
                    if command == "SONGWRITER" { sheet.songwriter = value }
                }
            case "INDEX":
                let index = token(&rest)
                if index == "01" || index == "1", currentEntry != nil {
                    guard currentEntry?.start == nil, let start = timestamp(token(&rest)) else {
                        throw ParseError.invalidSheet
                    }
                    currentEntry?.start = start
                }
            case "REM":
                let key = token(&rest).uppercased()
                let value = textValue(rest)
                if !inTrack {
                    if key == "GENRE" { sheet.genre = value }
                    if key == "DATE" { sheet.year = value }
                    if key == "DISCNUMBER" { sheet.discNumber = value.flatMap(Int.init) }
                }
            default: break // FLAGS, INDEX 00, PREGAP, ISRC and other extensions.
            }
        }
        try finishEntry()
        guard !sheet.entries.isEmpty else { throw ParseError.invalidSheet }
        var lastStartByFile: [String: Double] = [:]
        for entry in sheet.entries {
            guard let start = entry.start, start > (lastStartByFile[entry.file] ?? -1) else {
                throw ParseError.invalidSheet
            }
            lastStartByFile[entry.file] = start
        }
        return sheet
    }

    /// INDEX timestamps are minutes:seconds:CD frames (75 frames per second).
    static func timestamp(_ text: String) -> Double? {
        let components = text.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let minutes = Double(components[0]), let seconds = Int(components[1]),
              let frames = Int(components[2]), (0..<60).contains(seconds), (0..<75).contains(frames) else { return nil }
        let value = minutes * 60 + Double(seconds) + Double(frames) / 75
        return value.isFinite ? value : nil
    }

    /// Only reference enumerated audio files inside the granted library root.
    /// Exact path, case-insensitive path, then same-stem extension correction for
    /// common rips whose CUE still says .wav after conversion to .flac/.ape.
    func resolveSources(relativeTo sheetURL: URL, audioURLs: [URL]) throws -> [URL] {
        try entries.map { entry in
            let path = entry.file.replacingOccurrences(of: "\\", with: "/")
            guard !path.hasPrefix("/"), !path.contains(":") else { throw ParseError.invalidSheet }
            // Enumeration stores resolved paths. Resolve CUE aliases the same way,
            // but still require the target to belong to the enumerated audio set.
            let referencedURL = sheetURL.deletingLastPathComponent().appendingPathComponent(path)
            // Resolve the parent separately: a stale .wav filename may not exist,
            // in which case resolving the full URL leaves directory aliases intact.
            let candidate = referencedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(referencedURL.lastPathComponent)
                .resolvingSymlinksInPath().standardizedFileURL
            if let exact = audioURLs.first(where: { $0.path == candidate.path }) { return exact }
            let caseMatches = audioURLs.filter { $0.path.caseInsensitiveCompare(candidate.path) == .orderedSame }
            if caseMatches.count == 1 { return caseMatches[0] }
            let stemMatches = audioURLs.filter {
                $0.deletingPathExtension().path.caseInsensitiveCompare(candidate.deletingPathExtension().path) == .orderedSame
            }
            guard stemMatches.count == 1 else { throw ParseError.invalidSheet }
            return stemMatches[0]
        }
    }

    private static func textValue(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\"") { value = token(&value) }
        return value.isEmpty ? nil : value
    }

    private static func token(_ text: inout String) -> String {
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\"") {
            text.removeFirst()
            guard let end = text.firstIndex(of: "\"") else { text = ""; return "" }
            let result = String(text[..<end])
            text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        text = parts.count > 1 ? String(parts[1]) : ""
        return parts.first.map(String.init) ?? ""
    }
}
