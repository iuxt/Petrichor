import Foundation

extension CueTrackSegment {
    /// Project shared file timing into this track, retaining lines and syllables
    /// that cross the boundary. Track-specific sidecars bypass this projection.
    func lyrics(from albumLines: [LyricLine]) -> [LyricLine] {
        let timed = albumLines.contains { $0.startTime > 0 || $0.endTime != nil }
        guard timed else { return start == 0 ? albumLines : [] }
        return albumLines.enumerated().compactMap { index, line in
            let nextStart = line.endTime == nil ? albumLines.dropFirst(index + 1).first { $0.startTime > line.startTime }?.startTime : nil
            // Don't stretch a final, open-ended line into an uncovered next track.
            let inferredEnd = line.endTime ?? nextStart ?? (line.startTime >= start ? end : line.startTime)
            guard line.startTime < end, inferredEnd > start else { return nil }
            let clippedStart = max(line.startTime, start)
            let clippedEnd = min(inferredEnd, end)
            let segments = line.timingSegments?.map { word in
                let wordStart = line.startTime + word.startOffset
                let wordEnd = wordStart + word.duration
                return LyricTimingSegment(text: word.text,
                    startOffset: max(0, min(wordStart, clippedEnd) - clippedStart),
                    duration: max(0, min(wordEnd, clippedEnd) - max(wordStart, clippedStart)))
            }
            return LyricLine(text: line.text, startTime: clippedStart - start,
                             endTime: clippedEnd - start, timingSegments: segments, duetSide: line.duetSide)
        }
    }
}
