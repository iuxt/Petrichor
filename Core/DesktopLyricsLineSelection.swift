import Foundation

struct DesktopLyricsDisplayLines: Equatable {
    let current: LyricLine
    let next: LyricLine?
}

enum DesktopLyricsLineSelection {
    enum GapBehavior: Equatable {
        case empty
        case holdPreviousLine
    }

    static func syncedDisplayLines(
        lines: [LyricLine],
        at time: TimeInterval,
        gapBehavior: GapBehavior = .empty
    ) -> DesktopLyricsDisplayLines? {
        guard !lines.isEmpty else { return nil }

        let activeIndices = lines.indices.filter { lines[$0].isActive(at: time) }
        let duetPair = overlappingDuetPair(in: lines, activeIndices: activeIndices)
        let activeIndex = duetPair?.first ?? activeIndices.last

        let candidateIndex: Int?
        if let activeIndex {
            candidateIndex = nonEmptyIndex(in: lines, from: activeIndex)
        } else if let firstStartTime = lines.first?.startTime, time < firstStartTime {
            candidateIndex = nonEmptyIndex(in: lines, from: 0)
        } else {
            candidateIndex = nil
        }

        // An active blank tail also needs the hold fallback, not just a timing gap.
        let heldIndex = gapBehavior == .holdPreviousLine
            ? lastStartedNonEmptyIndex(in: lines, at: time)
            : nil
        guard let currentIndex = candidateIndex ?? heldIndex else {
            return nil
        }
        let nextIndex = duetPair?.second ?? nonEmptyIndex(in: lines, from: currentIndex + 1)

        return DesktopLyricsDisplayLines(
            current: lines[currentIndex],
            next: nextIndex.map { lines[$0] }
        )
    }

    static func plainDisplayLines(lines: [LyricLine]) -> DesktopLyricsDisplayLines? {
        guard let currentIndex = nonEmptyIndex(in: lines, from: 0) else {
            return nil
        }

        return DesktopLyricsDisplayLines(
            current: lines[currentIndex],
            next: nonEmptyIndex(in: lines, from: currentIndex + 1).map { lines[$0] }
        )
    }

    private static func nonEmptyIndex(in lines: [LyricLine], from startIndex: Int) -> Int? {
        guard startIndex < lines.count else { return nil }

        let boundedStart = max(0, startIndex)
        for index in boundedStart..<lines.count where !trimmedText(lines[index]).isEmpty {
            return index
        }
        return nil
    }

    private static func overlappingDuetPair(
        in lines: [LyricLine], activeIndices: [Int]
    ) -> (first: Int, second: Int)? {
        guard let left = activeIndices.first(where: { lines[$0].duetSide == .left && !trimmedText(lines[$0]).isEmpty }),
              let right = activeIndices.first(where: { lines[$0].duetSide == .right && !trimmedText(lines[$0]).isEmpty }) else {
            return nil
        }
        return left < right ? (left, right) : (right, left)
    }

    private static func lastStartedNonEmptyIndex(
        in lines: [LyricLine],
        at time: TimeInterval
    ) -> Int? {
        lines.lastIndex { line in
            time >= line.startTime && !trimmedText(line).isEmpty
        }
    }

    private static func trimmedText(_ line: LyricLine) -> String {
        line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
