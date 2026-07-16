import CoreFoundation
import Foundation

enum LyricsSource: Sendable, Equatable {
    case ksc
    case lrc
    case srt
    case embedded
    case none
}

enum LyricsSidecarLoader {
    struct Result: Sendable, Equatable {
        let lyrics: [LyricLine]
        let source: LyricsSource
    }

    static func load(
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) -> Result? {
        let baseURL = audioURL.deletingPathExtension()
        let candidates: [(extension: String, source: LyricsSource)] = [
            ("ksc", .ksc),
            ("lrc", .lrc),
            ("srt", .srt),
        ]

        for candidate in candidates {
            let url = baseURL.appendingPathExtension(candidate.extension)
            guard fileManager.fileExists(atPath: url.path),
                  let content = loadFileWithEncodingDetection(url, source: candidate.source),
                  !content.isEmpty else {
                continue
            }

            let lyrics: [LyricLine]
            switch candidate.source {
            case .ksc:
                lyrics = LyricLine.parseKSC(from: content)
            case .lrc:
                lyrics = LyricLine.parseLRC(from: content)
            case .srt:
                lyrics = LyricLine.parseSRT(from: content)
            case .embedded, .none:
                lyrics = []
            }

            if !lyrics.isEmpty {
                return Result(lyrics: lyrics, source: candidate.source)
            }
        }

        return nil
    }

    private static func loadFileWithEncodingDetection(_ url: URL, source: LyricsSource) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let content = String(data: data, encoding: .utf8) {
            return content
        }
        if data.starts(with: [0xFE, 0xFF]),
           let content = String(data: data, encoding: .utf16BigEndian) {
            return content
        }
        if data.starts(with: [0xFF, 0xFE]),
           let content = String(data: data, encoding: .utf16LittleEndian) {
            return content
        }
        if looksLikeUTF16(data) {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let content = String(data: data, encoding: encoding) {
                    return content
                }
            }
        }

        let ianaNames = source == .ksc
            ? ["GB18030", "GBK", "EUC-KR", "BIG5", "ISO-2022-JP"]
            : ["EUC-KR", "GB18030", "GBK", "BIG5", "ISO-2022-JP"]
        if source == .ksc {
            for name in ianaNames.prefix(2) {
                if let content = decode(data, ianaName: name) { return content }
            }
        }

        for encoding in [String.Encoding.shiftJIS, .japaneseEUC] {
            if let content = String(data: data, encoding: encoding) { return content }
        }
        for name in ianaNames.dropFirst(source == .ksc ? 2 : 0) {
            if let content = decode(data, ianaName: name) { return content }
        }
        for encoding in [String.Encoding.isoLatin1, .windowsCP1252] {
            if let content = String(data: data, encoding: encoding) { return content }
        }
        return nil
    }

    private static func decode(_ data: Data, ianaName: String) -> String? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String(data: data, encoding: String.Encoding(rawValue: nsEncoding))
    }

    private static func looksLikeUTF16(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data.prefix(128))
        let evenZeroes = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let oddZeroes = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        return max(evenZeroes, oddZeroes) >= bytes.count / 4
    }
}
