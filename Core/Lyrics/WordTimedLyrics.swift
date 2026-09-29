import Foundation

/// Converts provider word timing into Enhanced LRC, which the local LRC parser
/// can display with the same karaoke renderer used for KSC sidecars.
enum WordTimedLyrics {
    struct Word {
        let text: String
        let start: Int // absolute milliseconds
        let duration: Int
    }

    struct Line {
        let start: Int
        let duration: Int
        let words: [Word]
    }

    static func yrc(_ input: String) -> [Line] {
        parse(input, linePattern: #"^\[(\d+),(\d+)\](.*)$"#,
              wordPattern: #"\((\d+),(\d+),\d+\)"#, markerBeforeWord: true)
    }

    static func qrc(_ input: String) -> [Line] {
        parse(input, linePattern: #"^\[(\d+),(\d+)\](.*)$"#,
              wordPattern: #"\((\d+),(\d+)\)"#, markerBeforeWord: false)
    }

    static func enhancedLRC(_ lines: [Line], translations: [LyricLine] = []) -> String? {
        guard !lines.isEmpty else { return nil }
        var result: [String] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            guard !line.words.isEmpty else { continue }
            let text = line.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            var encoded = "[\(timestamp(line.start))]"
            for word in line.words {
                encoded += "<\(timestamp(word.start))>\(word.text)"
            }
            let end = min(86_399_999, max(line.start + line.duration,
                    line.words.map { $0.start + $0.duration }.max() ?? line.start))
            encoded += "<\(timestamp(end))>"
            if let translated = translations.min(by: { abs($0.startTime - Double(line.start) / 1000) < abs($1.startTime - Double(line.start) / 1000) }),
               abs(translated.startTime - Double(line.start) / 1000) <= 0.5,
               !translated.text.isEmpty {
                encoded += " / \(translated.text)"
            }
            result.append(encoded)
        }
        return result.isEmpty ? nil : result.joined(separator: "\n") + "\n"
    }

    private static func parse(_ input: String, linePattern: String, wordPattern: String, markerBeforeWord: Bool) -> [Line] {
        guard let lineRegex = try? NSRegularExpression(pattern: linePattern),
              let wordRegex = try? NSRegularExpression(pattern: wordPattern) else { return [] }
        var lines: [Line] = []
        for raw in input.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            guard let match = lineRegex.firstMatch(in: raw, range: range),
                  let startRange = Range(match.range(at: 1), in: raw),
                  let durationRange = Range(match.range(at: 2), in: raw),
                  let bodyRange = Range(match.range(at: 3), in: raw),
                  let start = Int(raw[startRange]), let duration = Int(raw[durationRange]),
                  start >= 0, start < 86_400_000, duration >= 0,
                  duration < 120_000 else { continue }
            let body = String(raw[bodyRange])
            let matches = wordRegex.matches(in: body, range: NSRange(body.startIndex..., in: body))
            guard !matches.isEmpty else { continue }
            var words: [Word] = []
            for (i, wordMatch) in matches.enumerated() {
                guard let timingRange = Range(wordMatch.range, in: body),
                      let timeRange = Range(wordMatch.range(at: 1), in: body),
                      let lengthRange = Range(wordMatch.range(at: 2), in: body),
                      let wordStart = Int(body[timeRange]), let wordDuration = Int(body[lengthRange]),
                      wordStart >= start, wordStart < 86_400_000,
                      wordDuration >= 0, wordDuration < 120_000 else { continue }
                let textRange: Range<String.Index>
                if markerBeforeWord {
                    let end = i + 1 < matches.count ? Range(matches[i + 1].range, in: body)!.lowerBound : body.endIndex
                    textRange = timingRange.upperBound..<end
                } else {
                    let begin = i == 0 ? body.startIndex : Range(matches[i - 1].range, in: body)!.upperBound
                    textRange = begin..<timingRange.lowerBound
                }
                let text = String(body[textRange])
                if !text.isEmpty { words.append(Word(text: text, start: wordStart, duration: wordDuration)) }
            }
            guard !words.isEmpty, zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { continue }
            lines.append(Line(start: start, duration: duration, words: words))
        }
        return lines
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d.%03d", milliseconds / 60_000, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
