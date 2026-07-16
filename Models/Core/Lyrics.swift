import Foundation

struct LyricTimingSegment: Codable, Equatable, Sendable {
    let text: String
    let startOffset: TimeInterval
    let duration: TimeInterval
}

struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let text: String
    let startTime: TimeInterval // seconds
    var endTime: TimeInterval?  // seconds; nil for the last line
    let timingSegments: [LyricTimingSegment]?
    
    init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        timingSegments: [LyricTimingSegment]? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.timingSegments = timingSegments
    }
}

typealias Lyrics = [LyricLine]

extension LyricLine {
    /// Normalize CRLF / lone CR line endings to LF so block- and line-splitting
    /// behave consistently regardless of how the lyric file was authored.
    private static func normalizingNewlines(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func parseKSC(from kscString: String) -> Lyrics {
        var parsed: [(inputIndex: Int, line: LyricLine)] = []

        for (inputIndex, rawLine) in normalizingNewlines(kscString).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let arguments = kscArguments(from: String(rawLine)),
                  arguments.count >= 4,
                  let startTime = kscTime(arguments[0]),
                  let endTime = kscTime(arguments[1]),
                  endTime >= startTime else {
                continue
            }

            let text = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            parsed.append((
                inputIndex,
                LyricLine(
                    text: text,
                    startTime: startTime,
                    endTime: endTime,
                    timingSegments: kscTimingSegments(text: text, rawDurations: arguments[3])
                )
            ))
        }

        return parsed.sorted { lhs, rhs in
            if lhs.line.startTime == rhs.line.startTime {
                return lhs.inputIndex < rhs.inputIndex
            }
            return lhs.line.startTime < rhs.line.startTime
        }.map(\.line)
    }

    private static func kscArguments(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("karaoke.add"),
              let openingParenthesis = trimmed.firstIndex(of: "("),
              let closingParenthesis = trimmed.lastIndex(of: ")"),
              openingParenthesis < closingParenthesis else {
            return nil
        }

        let body = trimmed[trimmed.index(after: openingParenthesis)..<closingParenthesis]
        var arguments: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaping = false

        for character in body {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if isQuoted && character == "\\" {
                isEscaping = true
            } else if character == "'" {
                isQuoted.toggle()
            } else if character == "," && !isQuoted {
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        guard !isQuoted else { return nil }
        if isEscaping { current.append("\\") }
        arguments.append(current.trimmingCharacters(in: .whitespaces))
        return arguments.count >= 4 ? arguments : nil
    }

    private static func kscTime(_ raw: String) -> TimeInterval? {
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2 || fields.count == 3,
              let seconds = Double(fields.last ?? ""),
              seconds >= 0, seconds < 60 else {
            return nil
        }

        if fields.count == 2 {
            guard let minutes = Double(fields[0]), minutes >= 0 else { return nil }
            return minutes * 60 + seconds
        }

        guard let hours = Double(fields[0]), hours >= 0,
              let minutes = Double(fields[1]), minutes >= 0, minutes < 60 else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func kscTimingSegments(text: String, rawDurations: String) -> [LyricTimingSegment]? {
        let rawValues = rawDurations.split(separator: ",", omittingEmptySubsequences: false)
        guard !rawValues.isEmpty else { return nil }

        var durations: [TimeInterval] = []
        for rawValue in rawValues {
            guard let milliseconds = Int(rawValue.trimmingCharacters(in: .whitespaces)), milliseconds >= 0 else {
                return nil
            }
            durations.append(TimeInterval(milliseconds) / 1000)
        }

        let graphemes = text.map(String.init)
        guard graphemes.count == durations.count else { return nil }

        var offset: TimeInterval = 0
        return zip(graphemes, durations).map { text, duration in
            defer { offset += duration }
            return LyricTimingSegment(text: text, startOffset: offset, duration: duration)
        }
    }

    /// Parse the lyrics from the LRC files
    static func parseLRC(from lrcString: String) -> Lyrics {
        let lines = normalizingNewlines(lrcString).components(separatedBy: "\n")
        var lyrics: [LyricLine] = []

        // Use the regular expression to parse the time stamps
        let pattern = "\\[(\\d+):(\\d+)(?:\\.(\\d+))?\\]"
        // Enhanced-LRC inline word timing tags, e.g. <00:12.50>, are stripped from the displayed text
        let wordTagPattern = "<\\d+:\\d+(?:\\.\\d+)?>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return lyrics
        }
        
        for line in lines {
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            let timestamps = matches.map { match -> TimeInterval in
                let nsLine = line as NSString
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                
                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0

                let timeWithoutMs = minutes * 60 + seconds

                let msRange = match.range(at: 3)
                if msRange.location != NSNotFound, msRange.length > 0 {
                    let msStr = nsLine.substring(with: msRange)
                    let msValue = Double(msStr) ?? 0
                    let divisor = pow(10.0, Double(msStr.count))
                    return timeWithoutMs + msValue / divisor
                } else {
                    return timeWithoutMs
                }
            }
            
            // Get the plain text part from the lyric
            let text = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                .replacingOccurrences(of: wordTagPattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            
            for timestamp in timestamps {
                lyrics.append(LyricLine(text: text, startTime: timestamp))
            }
        }
        
        var sorted = lyrics.sorted { $0.startTime < $1.startTime }
        // Each line ends where the next begins, giving a gapless highlight window
        if sorted.count > 1 {
            for i in 0..<sorted.count - 1 {
                sorted[i].endTime = sorted[i + 1].startTime
            }
        }
        return sorted
    }
    
    /// Parse the lyrics from the SRT files
    static func parseSRT(from srtString: String) -> Lyrics {
        // Divide the content into blocks based on blank lines.
        let blocks = normalizingNewlines(srtString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        var lyrics: Lyrics = []
        
        let timePattern = "^(\\d{2}):(\\d{2}):(\\d{2}),(\\d{3}) --> (\\d{2}):(\\d{2}):(\\d{2}),(\\d{3})$"
        guard let timeRegex = try? NSRegularExpression(pattern: timePattern, options: .anchorsMatchLines) else {
            return lyrics
        }
        
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

            // The SRT/WebSRT sequence number is optional: a block may be either
            //   "<index>\n<time>\n<text...>" (>= 3 lines)
            //   "<time>\n<text...>"            (>= 2 lines)
            // Detect which form we have by checking whether the first line is a pure
            // integer; if not, treat it as the time line. Without this, index-less
            // blocks (valid per spec, emitted by many tools) are silently dropped.
            let hasSequenceNumber = lines.first.map { Int($0) != nil } ?? false
            let timeIndex = hasSequenceNumber ? 1 : 0

            guard lines.count >= timeIndex + 2 else { continue }

            let timeLine = lines[timeIndex]
            guard let match = timeRegex.firstMatch(in: timeLine, range: NSRange(timeLine.startIndex..., in: timeLine)) else {
                continue
            }

            let nsLine = timeLine as NSString
            // Start time
            let startH = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
            let startM = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
            let startS = Double(nsLine.substring(with: match.range(at: 3))) ?? 0
            let startMs = Double(nsLine.substring(with: match.range(at: 4))) ?? 0
            let startTime = startH * 3600 + startM * 60 + startS + startMs / 1000.0

            // End time
            let endH = Double(nsLine.substring(with: match.range(at: 5))) ?? 0
            let endM = Double(nsLine.substring(with: match.range(at: 6))) ?? 0
            let endS = Double(nsLine.substring(with: match.range(at: 7))) ?? 0
            let endMs = Double(nsLine.substring(with: match.range(at: 8))) ?? 0
            let endTime = endH * 3600 + endM * 60 + endS + endMs / 1000.0

            // Remaining lines (after the time line) are the subtitle text
            let textLines = lines.dropFirst(timeIndex + 1)
            let text = textLines.joined(separator: "\n")

            lyrics.append(LyricLine(text: text, startTime: startTime, endTime: endTime))
        }

        return lyrics.sorted { $0.startTime < $1.startTime }
    }
}
