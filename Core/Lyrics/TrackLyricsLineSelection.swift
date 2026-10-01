import Foundation

enum TrackLyricsLineSelection {
    static func currentIndex(
        in lines: [LyricLine],
        at time: TimeInterval,
        holdPreviousLine: Bool
    ) -> Int {
        if let activeIndex = lines.lastIndex(where: { line in
            line.isActive(at: time) && (!holdPreviousLine || hasText(line))
        }) {
            return activeIndex
        }

        // Recompute from the playhead so seeks and track changes cannot retain
        // a stale highlight. Blank interval markers should not steal the focus.
        guard holdPreviousLine else { return -1 }
        return lines.lastIndex { line in
            line.startTime <= time && hasText(line)
        } ?? -1
    }

    private static func hasText(_ line: LyricLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
