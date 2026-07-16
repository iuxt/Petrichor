# KSC Word Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline `.ksc` sidecar loading and smooth per-grapheme karaoke highlighting to every Petrichor lyrics surface.

**Architecture:** Extend `LyricLine` with optional timing segments, parse KSC into that shared model, and move external sidecar loading into a Foundation-only unit. A pure timing layer and one focused AppKit-backed SwiftUI component provide 30 FPS local interpolation and glyph clipping without increasing the global playback timer frequency; existing LRC/SRT and line-level views remain the fallback.

**Tech Stack:** Swift, Foundation/CoreFoundation, SwiftUI, AppKit TextKit, GRDB integration through the existing `LyricsLoader`, shell-based Swift regression checks, Xcode 16, macOS 14+

## Global Constraints

- Keep Xcode 16, macOS 14+, and the current Swift/SwiftUI/AppKit stack.
- Add no third-party dependencies.
- Keep lyrics offline; do not add runtime network access, analytics, or background data collection.
- Read existing KSC sidecars only; do not edit KSC files or audio files.
- Keep file IO off the main actor and preserve security-scoped URL behavior.
- Do not change the database schema, ordinary playlist storage, or localization resources.
- Preserve existing LRC, SRT, embedded lyrics, cache, scrolling, and Trash fallback behavior.
- The Xcode project uses file-system-synchronized `Core`, `Models`, `Views`, and `Scripts` groups, so new files require no `project.pbxproj` edit.

---

## File Map

- `Models/Core/Lyrics.swift`: shared timing-segment model and KSC parser.
- `Core/LyricsSidecarLoader.swift`: Foundation-only sidecar priority, decoding, and format dispatch.
- `Core/LyricsLoader.swift`: database fallback orchestration; delegates external files to `LyricsSidecarLoader`.
- `Core/KaraokeTiming.swift`: pure segment-fill and monotonic playback-time interpolation.
- `Views/Components/KaraokeLyricText.swift`: shared SwiftUI API and focused TextKit renderer.
- `Views/Main/TrackLyricsView.swift`: shared main/mini/immersive integration.
- `Core/DesktopLyricsLineSelection.swift`: carries full `LyricLine` values to the desktop surface.
- `Views/DesktopLyrics/DesktopLyricsView.swift`: desktop current-line integration.
- `Core/TrackTrashSidecars.swift`: recognizes `.ksc` as a lyric sidecar.
- `Scripts/test-lyrics-parsing.sh`: parser regression coverage.
- `Scripts/test-lyrics-sidecar-loading.sh`: real sidecar priority and encoding coverage.
- `Scripts/test-karaoke-timing.sh`: pure time/progress coverage.
- `Scripts/test-karaoke-lyrics-rendering.sh`: renderer typecheck and integration guards.
- `Scripts/test-lyrics-background-io.sh`: preserves detached external-file loading.
- `Scripts/test-desktop-lyrics-line-selection.sh`: desktop full-line selection coverage.
- `Scripts/test-track-trash-sidecars.sh`: KSC Trash sidecar coverage.

---

### Task 1: Shared KSC timing model and parser

**Files:**
- Modify: `Models/Core/Lyrics.swift:3-141`
- Modify: `Scripts/test-lyrics-parsing.sh:1-105`

**Interfaces:**
- Consumes: existing `LyricLine(text:startTime:endTime:)`, `parseLRC(from:)`, and `parseSRT(from:)`.
- Produces: `LyricTimingSegment`, `LyricLine.timingSegments`, `LyricLine.parseKSC(from:) -> Lyrics`.

- [ ] **Step 1: Add failing KSC parser checks**

Insert the following block before the existing empty/garbage checks in `Scripts/test-lyrics-parsing.sh`:

```swift
// --- KSC: line timing, stable sorting, escapes, grapheme timing ---
let ksc = #"""
karaoke.songname := 'ignored metadata';
karaoke.add('0:12.500', '0:14.000', 'A\'好👨‍👩‍👧‍👦', '100,200,300,400');
karaoke.add('00:00:02.250', '00:00:03.000', '先', '750');
"""#
let kscLines = LyricLine.parseKSC(from: ksc.replacingOccurrences(of: "\n", with: "\r\n"))
precondition(kscLines.count == 2, "Expected 2 KSC lines, got \(kscLines.count)")
precondition(kscLines[0].text == "先" && abs(kscLines[0].startTime - 2.25) < 0.001,
             "KSC lines must be sorted by start time")
precondition(kscLines[1].text == "A'好👨‍👩‍👧‍👦", "KSC escaped lyric text was parsed incorrectly")
precondition(kscLines[1].endTime == 14.0, "KSC end time was parsed incorrectly")
let segments = kscLines[1].timingSegments ?? []
precondition(segments.count == 4, "Expected one KSC segment per grapheme cluster")
precondition(segments.map(\.text) == ["A", "'", "好", "👨‍👩‍👧‍👦"], "KSC grapheme splitting was incorrect")
precondition(abs(segments[1].startOffset - 0.1) < 0.001 && abs(segments[3].startOffset - 0.6) < 0.001,
             "KSC segment offsets were not accumulated")
precondition(abs(segments[3].duration - 0.4) < 0.001, "KSC millisecond duration was not converted to seconds")

// --- KSC: invalid segment metadata degrades without dropping the line ---
let kscFallback = """
karaoke.add('00:01.000', '00:02.000', '两个', '500');
karaoke.add('00:02.000', '00:03.000', '坏时长', '100,nope,300');
karaoke.add('00:03.000', '00:04.000', '零', '0');
karaoke.add('00:05.000', '00:04.000', '倒序', '100,100');
"""
let fallbackLines = LyricLine.parseKSC(from: kscFallback)
precondition(fallbackLines.count == 3, "Only the reversed KSC line should be dropped")
precondition(fallbackLines[0].timingSegments == nil, "Mismatched KSC duration count must degrade to line timing")
precondition(fallbackLines[1].timingSegments == nil, "Non-numeric KSC duration must degrade to line timing")
precondition(fallbackLines[2].timingSegments?.first?.duration == 0, "Zero-duration KSC segments must remain valid")
print("KSC parsing and degradation OK")
```

Extend the empty-input section with:

```swift
precondition(LyricLine.parseKSC(from: "").isEmpty, "Empty KSC should yield no lines")
precondition(LyricLine.parseKSC(from: "karaoke.clear();").isEmpty, "KSC without add commands should yield no lines")
```

- [ ] **Step 2: Run the parser check and confirm RED**

Run: `Scripts/test-lyrics-parsing.sh`

Expected: compilation fails because `LyricLine.parseKSC` and `timingSegments` do not exist.

- [ ] **Step 3: Extend the model and add the minimal parser**

Add this type above `LyricLine` and add the property/initializer argument shown below:

```swift
struct LyricTimingSegment: Codable, Equatable, Sendable {
    let text: String
    let startOffset: TimeInterval
    let duration: TimeInterval
}

struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let text: String
    let startTime: TimeInterval
    var endTime: TimeInterval?
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
```

Add these methods inside `extension LyricLine` after `normalizingNewlines`:

```swift
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
```

- [ ] **Step 4: Run the parser check and confirm GREEN**

Run: `Scripts/test-lyrics-parsing.sh`

Expected: every LRC, SRT, and KSC assertion passes and the script prints `All lyrics parsing tests passed`.

- [ ] **Step 5: Commit the model/parser cycle**

```bash
git add Models/Core/Lyrics.swift Scripts/test-lyrics-parsing.sh
git commit -m "feat(lyrics): parse KSC timing segments"
```

---

### Task 2: Foundation-only sidecar loader and KSC priority

**Files:**
- Create: `Core/LyricsSidecarLoader.swift`
- Create: `Scripts/test-lyrics-sidecar-loading.sh`
- Modify: `Core/LyricsLoader.swift:10-150`
- Modify: `Scripts/test-lyrics-background-io.sh:4-18`

**Interfaces:**
- Consumes: `LyricLine.parseKSC(from:)`, `parseLRC(from:)`, `parseSRT(from:)` from Task 1.
- Produces: `LyricsSource`, `LyricsSidecarLoader.Result`, and `LyricsSidecarLoader.load(forAudioURL:fileManager:)`.

- [ ] **Step 1: Write the failing real-file sidecar check**

Create `Scripts/test-lyrics-sidecar-loading.sh` with this executable content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

touch "$TMP_DIR/Priority.flac" "$TMP_DIR/Fallback.flac" "$TMP_DIR/GBK.flac"
printf "%s\n" "karaoke.add('00:01.000','00:02.000','KSC','1000');" > "$TMP_DIR/Priority.ksc"
printf "%s\n" "[00:01.00]LRC" > "$TMP_DIR/Priority.lrc"
printf "%s\n" "not valid ksc" > "$TMP_DIR/Fallback.ksc"
printf "%s\n" "[00:02.00]fallback" > "$TMP_DIR/Fallback.lrc"
printf "%s\n" "karaoke.add('00:03.000','00:04.000','中文','500,500');" \
    | iconv -f UTF-8 -t GBK > "$TMP_DIR/GBK.ksc"

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func require(_ name: String) -> LyricsSidecarLoader.Result {
    guard let result = LyricsSidecarLoader.load(forAudioURL: root.appendingPathComponent("\(name).flac")) else {
        fatalError("Missing sidecar result for \(name)")
    }
    return result
}

let priority = require("Priority")
precondition(priority.source == .ksc && priority.lyrics.first?.text == "KSC", "KSC must outrank LRC")

let fallback = require("Fallback")
precondition(fallback.source == .lrc && fallback.lyrics.first?.text == "fallback", "Invalid KSC must fall back to LRC")

let gbk = require("GBK")
precondition(gbk.source == .ksc && gbk.lyrics.first?.text == "中文", "GBK KSC decoding failed")

print("Lyrics sidecar loading checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/LyricsSidecarLoader.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/lyrics-sidecar-test"

"$TMP_DIR/lyrics-sidecar-test" "$TMP_DIR"
```

Make it executable with: `chmod +x Scripts/test-lyrics-sidecar-loading.sh`.

Update `Scripts/test-lyrics-background-io.sh` so its second guard checks the new delegation call:

```bash
if ! rg -n 'LyricsSidecarLoader\.load\(forAudioURL:' "$source_file" >/dev/null; then
    printf 'LyricsLoader external sidecar delegation is missing.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run both checks and confirm RED**

Run: `Scripts/test-lyrics-sidecar-loading.sh && Scripts/test-lyrics-background-io.sh`

Expected: the first check fails because `Core/LyricsSidecarLoader.swift` does not exist; the background check still passes against the old helper until the production refactor begins.

- [ ] **Step 3: Create the sidecar loader**

Create `Core/LyricsSidecarLoader.swift` with:

```swift
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
```

- [ ] **Step 4: Delegate from `LyricsLoader` and remove duplicate code**

Replace the detached external load in `Core/LyricsLoader.swift` with:

```swift
// 1. External KSC/LRC/SRT files
let audioURL = track.url
let external = await Task.detached(priority: .utility) {
    LyricsSidecarLoader.load(forAudioURL: audioURL)
}.value
if let external {
    lines = external.lyrics
    source = external.source
}
```

Delete `loadExternalLyrics`, `loadFileWithEncodingDetection`, and the old `LyricsSource` declaration from `Core/LyricsLoader.swift`. Keep `parseAnyLyrics` private and unchanged for embedded lyrics.

- [ ] **Step 5: Run sidecar/background/parser checks and confirm GREEN**

Run:

```bash
Scripts/test-lyrics-sidecar-loading.sh
Scripts/test-lyrics-background-io.sh
Scripts/test-lyrics-parsing.sh
```

Expected: all three scripts pass; the sidecar check prints `Lyrics sidecar loading checks passed`.

- [ ] **Step 6: Commit the sidecar cycle**

```bash
git add Core/LyricsSidecarLoader.swift Core/LyricsLoader.swift Scripts/test-lyrics-sidecar-loading.sh Scripts/test-lyrics-background-io.sh
git commit -m "feat(lyrics): load KSC sidecars"
```

---

### Task 3: Pure karaoke progress and monotonic interpolation

**Files:**
- Create: `Core/KaraokeTiming.swift`
- Create: `Scripts/test-karaoke-timing.sh`

**Interfaces:**
- Consumes: `LyricLine.timingSegments`, `LyricTimingSegment.startOffset`, and `duration` from Task 1.
- Produces: `KaraokeTiming.fillFractions(for:at:) -> [Double]?` and `KaraokePlaybackTimeAnchor.time(at:upperBound:) -> TimeInterval`.

- [ ] **Step 1: Write the failing pure timing check**

Create `Scripts/test-karaoke-timing.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertClose(_ actual: Double, _ expected: Double, _ message: String) {
    precondition(abs(actual - expected) < 0.0001, "\(message): expected \(expected), got \(actual)")
}

let line = LyricLine(
    text: "ab",
    startTime: 10,
    endTime: 12,
    timingSegments: [
        LyricTimingSegment(text: "a", startOffset: 0, duration: 0.5),
        LyricTimingSegment(text: "b", startOffset: 0.5, duration: 1),
    ]
)

precondition(KaraokeTiming.fillFractions(for: line, at: 9.5) == [0, 0], "Progress before the line must be empty")
let firstMiddle = KaraokeTiming.fillFractions(for: line, at: 10.25)!
assertClose(firstMiddle[0], 0.5, "First glyph midpoint")
assertClose(firstMiddle[1], 0, "Second glyph before start")
precondition(KaraokeTiming.fillFractions(for: line, at: 10.5) == [1, 0], "Glyph boundary must be exact")
let secondMiddle = KaraokeTiming.fillFractions(for: line, at: 11)!
assertClose(secondMiddle[1], 0.5, "Second glyph midpoint")
precondition(KaraokeTiming.fillFractions(for: line, at: 12) == [1, 1], "Line end must complete all glyphs")
precondition(KaraokeTiming.fillFractions(for: LyricLine(text: "plain", startTime: 0), at: 1) == nil,
             "Untimed lines must not synthesize glyph progress")

let clock = ContinuousClock()
let instant = clock.now
let playing = KaraokePlaybackTimeAnchor(sampleTime: 4, sampleInstant: instant, isPlaying: true)
assertClose(playing.time(at: instant.advanced(by: .milliseconds(250)), upperBound: 10), 4.25, "Playing anchor interpolation")
assertClose(playing.time(at: instant.advanced(by: .seconds(20)), upperBound: 5), 5, "Anchor upper-bound clamp")

let paused = KaraokePlaybackTimeAnchor(sampleTime: 4, sampleInstant: instant, isPlaying: false)
assertClose(paused.time(at: instant.advanced(by: .seconds(2)), upperBound: 10), 4, "Paused anchors must freeze")

let seeked = KaraokePlaybackTimeAnchor(sampleTime: 1.5, sampleInstant: instant, isPlaying: true)
assertClose(seeked.time(at: instant.advanced(by: .milliseconds(100)), upperBound: nil), 1.6, "A new anchor must reset after seeking")

print("Karaoke timing checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/karaoke-timing-test"

"$TMP_DIR/karaoke-timing-test"
```

Make it executable with: `chmod +x Scripts/test-karaoke-timing.sh`.

- [ ] **Step 2: Run the timing check and confirm RED**

Run: `Scripts/test-karaoke-timing.sh`

Expected: compilation fails because `Core/KaraokeTiming.swift`, `KaraokeTiming`, and `KaraokePlaybackTimeAnchor` do not exist.

- [ ] **Step 3: Add the minimal pure timing types**

Create `Core/KaraokeTiming.swift` with:

```swift
import Foundation

enum KaraokeTiming {
    static func fillFractions(for line: LyricLine, at playbackTime: TimeInterval) -> [Double]? {
        guard let segments = line.timingSegments, !segments.isEmpty else { return nil }
        if let endTime = line.endTime, playbackTime >= endTime {
            return Array(repeating: 1, count: segments.count)
        }

        let localTime = playbackTime - line.startTime
        return segments.map { segment in
            if localTime < segment.startOffset { return 0 }
            if segment.duration == 0 { return 1 }
            return min(1, max(0, (localTime - segment.startOffset) / segment.duration))
        }
    }
}

struct KaraokePlaybackTimeAnchor: Sendable {
    let sampleTime: TimeInterval
    let sampleInstant: ContinuousClock.Instant
    let isPlaying: Bool

    func time(
        at instant: ContinuousClock.Instant,
        upperBound: TimeInterval?
    ) -> TimeInterval {
        let elapsed: TimeInterval
        if isPlaying {
            let components = sampleInstant.duration(to: instant).components
            elapsed = max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        } else {
            elapsed = 0
        }

        let interpolated = max(0, sampleTime + elapsed)
        return upperBound.map { min(interpolated, $0) } ?? interpolated
    }
}
```

- [ ] **Step 4: Run the timing and parser checks and confirm GREEN**

Run: `Scripts/test-karaoke-timing.sh && Scripts/test-lyrics-parsing.sh`

Expected: both pass, with `Karaoke timing checks passed` from the new check.

- [ ] **Step 5: Commit the timing cycle**

```bash
git add Core/KaraokeTiming.swift Scripts/test-karaoke-timing.sh
git commit -m "feat(lyrics): calculate karaoke glyph progress"
```

---

### Task 4: Shared TextKit karaoke renderer

**Files:**
- Create: `Views/Components/KaraokeLyricText.swift`
- Create: `Scripts/test-karaoke-lyrics-rendering.sh`

**Interfaces:**
- Consumes: `KaraokeTiming.fillFractions`, `KaraokePlaybackTimeAnchor`, and timed `LyricLine` values.
- Produces: `KaraokeFontWeight` and `KaraokeLyricText` with parameters `line`, `sampleTime`, `isPlaying`, `fontName`, `fontSize`, `fontWeight`, `activeColor`, `inactiveColor`, `lineLimit`, and `lineSpacing`.

- [ ] **Step 1: Write the failing renderer typecheck**

Create `Scripts/test-karaoke-lyrics-rendering.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Views/Components/KaraokeLyricText.swift"

test -f "$SOURCE" || { printf 'Missing shared KaraokeLyricText component.\n' >&2; exit 1; }
rg -n 'struct KaraokeLyricText: View' "$SOURCE" >/dev/null
rg -n 'NSViewRepresentable' "$SOURCE" >/dev/null
rg -n 'NSLayoutManager' "$SOURCE" >/dev/null
rg -n 'TimelineView\(\.animation' "$SOURCE" >/dev/null
rg -n 'accessibilityLabel' "$SOURCE" >/dev/null
rg -n 'fineProgressSampling \? \.milliseconds\(500\) : \.seconds\(1\)' \
    "$ROOT_DIR/Managers/PlaybackManager.swift" >/dev/null || {
    printf 'Karaoke rendering must not raise the global playback timer frequency.\n' >&2
    exit 1
}

xcrun swiftc -typecheck \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$SOURCE"

printf 'Karaoke lyrics renderer checks passed\n'
```

Make it executable with: `chmod +x Scripts/test-karaoke-lyrics-rendering.sh`.

- [ ] **Step 2: Run the renderer check and confirm RED**

Run: `Scripts/test-karaoke-lyrics-rendering.sh`

Expected: it fails with `Missing shared KaraokeLyricText component.`

- [ ] **Step 3: Create the shared SwiftUI/TextKit component**

Create `Views/Components/KaraokeLyricText.swift`. The file must contain these concrete units:

```swift
import AppKit
import Foundation
import SwiftUI

enum KaraokeFontWeight {
    case regular
    case semibold
    case bold

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

struct KaraokeLyricText: View {
    let line: LyricLine
    let sampleTime: TimeInterval
    let isPlaying: Bool
    let fontName: String?
    let fontSize: CGFloat
    let fontWeight: KaraokeFontWeight
    let activeColor: Color
    let inactiveColor: Color
    let lineLimit: Int
    let lineSpacing: CGFloat

    @State private var anchor: KaraokePlaybackTimeAnchor
    private let clock: ContinuousClock

    init(
        line: LyricLine,
        sampleTime: TimeInterval,
        isPlaying: Bool,
        fontName: String? = nil,
        fontSize: CGFloat,
        fontWeight: KaraokeFontWeight,
        activeColor: Color,
        inactiveColor: Color,
        lineLimit: Int = 0,
        lineSpacing: CGFloat = 0
    ) {
        self.line = line
        self.sampleTime = sampleTime
        self.isPlaying = isPlaying
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.lineLimit = lineLimit
        self.lineSpacing = lineSpacing

        let clock = ContinuousClock()
        self.clock = clock
        _anchor = State(initialValue: KaraokePlaybackTimeAnchor(
            sampleTime: sampleTime,
            sampleInstant: clock.now,
            isPlaying: isPlaying
        ))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let renderTime = anchor.time(at: clock.now, upperBound: line.endTime)
            KaraokeTextRepresentable(
                line: line,
                fillFractions: KaraokeTiming.fillFractions(for: line, at: renderTime) ?? [],
                fontName: fontName,
                fontSize: fontSize,
                fontWeight: fontWeight,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                lineLimit: lineLimit,
                lineSpacing: lineSpacing
            )
        }
        .onChange(of: sampleTime) { _, newTime in resetAnchor(time: newTime, playing: isPlaying) }
        .onChange(of: isPlaying) { _, playing in resetAnchor(time: sampleTime, playing: playing) }
        .onChange(of: line.id) { _, _ in resetAnchor(time: sampleTime, playing: isPlaying) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.text))
    }

    private func resetAnchor(time: TimeInterval, playing: Bool) {
        anchor = KaraokePlaybackTimeAnchor(sampleTime: time, sampleInstant: clock.now, isPlaying: playing)
    }
}
```

In the same file, add the complete TextKit bridge below:

```swift
private struct KaraokeTextRepresentable: NSViewRepresentable {
    let line: LyricLine
    let fillFractions: [Double]
    let fontName: String?
    let fontSize: CGFloat
    let fontWeight: KaraokeFontWeight
    let activeColor: Color
    let inactiveColor: Color
    let lineLimit: Int
    let lineSpacing: CGFloat

    func makeNSView(context: Context) -> KaraokeTextNSView {
        let view = KaraokeTextNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: KaraokeTextNSView, context: Context) {
        update(nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: KaraokeTextNSView,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize(forWidth: max(1, proposal.width ?? 1))
    }

    private func update(_ view: KaraokeTextNSView) {
        view.configure(
            line: line,
            fillFractions: fillFractions,
            fontName: fontName,
            fontSize: fontSize,
            fontWeight: fontWeight,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            lineLimit: lineLimit,
            lineSpacing: lineSpacing
        )
    }
}

private final class KaraokeTextNSView: NSView {
    private let baseStorage = NSTextStorage()
    private let baseLayout = NSLayoutManager()
    private let baseContainer = NSTextContainer(size: .zero)
    private let activeStorage = NSTextStorage()
    private let activeLayout = NSLayoutManager()
    private let activeContainer = NSTextContainer(size: .zero)

    private var line = LyricLine(text: "", startTime: 0)
    private var fillFractions: [Double] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpTextKit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpTextKit()
    }

    private func setUpTextKit() {
        baseStorage.addLayoutManager(baseLayout)
        baseLayout.addTextContainer(baseContainer)
        activeStorage.addLayoutManager(activeLayout)
        activeLayout.addTextContainer(activeContainer)
        for container in [baseContainer, activeContainer] {
            container.lineFragmentPadding = 0
        }
        setAccessibilityElement(false)
    }

    func configure(
        line: LyricLine,
        fillFractions: [Double],
        fontName: String?,
        fontSize: CGFloat,
        fontWeight: KaraokeFontWeight,
        activeColor: Color,
        inactiveColor: Color,
        lineLimit: Int,
        lineSpacing: CGFloat
    ) {
        self.line = line
        self.fillFractions = fillFractions

        let font = makeFont(name: fontName, size: fontSize, weight: fontWeight.nsWeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = lineLimit == 1 ? .byTruncatingTail : .byWordWrapping

        baseStorage.setAttributedString(NSAttributedString(
            string: line.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(inactiveColor),
                .paragraphStyle: paragraph,
            ]
        ))
        activeStorage.setAttributedString(NSAttributedString(
            string: line.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(activeColor),
                .paragraphStyle: paragraph,
            ]
        ))

        for container in [baseContainer, activeContainer] {
            container.maximumNumberOfLines = lineLimit
            container.lineBreakMode = paragraph.lineBreakMode
        }
        updateContainerWidth(max(1, bounds.width))
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateContainerWidth(max(1, bounds.width))
    }

    func fittingSize(forWidth width: CGFloat) -> CGSize {
        updateContainerWidth(width)
        baseLayout.ensureLayout(for: baseContainer)
        let used = baseLayout.usedRect(for: baseContainer)
        return CGSize(width: width, height: max(1, ceil(used.height)))
    }

    override var intrinsicContentSize: NSSize {
        fittingSize(forWidth: max(1, bounds.width))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        baseLayout.ensureLayout(for: baseContainer)
        activeLayout.ensureLayout(for: activeContainer)

        let used = baseLayout.usedRect(for: baseContainer)
        let origin = NSPoint(x: 0, y: max(0, (bounds.height - used.height) / 2 - used.minY))
        let baseGlyphs = baseLayout.glyphRange(for: baseContainer)
        baseLayout.drawGlyphs(forGlyphRange: baseGlyphs, at: origin)

        guard let segments = line.timingSegments,
              segments.count == fillFractions.count else {
            return
        }

        var startIndex = line.text.startIndex
        for (segment, rawFraction) in zip(segments, fillFractions) {
            guard let endIndex = line.text.index(
                startIndex,
                offsetBy: segment.text.count,
                limitedBy: line.text.endIndex
            ) else {
                break
            }

            let characterRange = NSRange(startIndex..<endIndex, in: line.text)
            startIndex = endIndex
            let fraction = min(1, max(0, rawFraction))
            guard fraction > 0 else { continue }

            let glyphRange = activeLayout.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var clipRect = activeLayout.boundingRect(forGlyphRange: glyphRange, in: activeContainer)
            clipRect.origin.x += origin.x
            clipRect.origin.y += origin.y
            clipRect.size.width *= CGFloat(fraction)
            guard clipRect.width > 0, clipRect.height > 0 else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clipRect).addClip()
            activeLayout.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func updateContainerWidth(_ width: CGFloat) {
        let size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        baseContainer.containerSize = size
        activeContainer.containerSize = size
    }

    private func makeFont(name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let name {
            let descriptor = NSFontDescriptor(name: name, size: size).addingAttributes([
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
            if let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}
```

This TextKit code is intentionally isolated in one component because SwiftUI `Text` cannot expose the glyph rectangles needed for partial-character clipping on macOS 14.

- [ ] **Step 4: Run the renderer and timing checks and confirm GREEN**

Run: `Scripts/test-karaoke-lyrics-rendering.sh && Scripts/test-karaoke-timing.sh`

Expected: both pass; `swiftc -typecheck` reports no diagnostics.

- [ ] **Step 5: Commit the renderer cycle**

```bash
git add Views/Components/KaraokeLyricText.swift Scripts/test-karaoke-lyrics-rendering.sh
git commit -m "feat(lyrics): render smooth karaoke highlights"
```

---

### Task 5: Main, mini-player, and immersive lyrics integration

**Files:**
- Modify: `Views/Main/TrackLyricsView.swift:38-235`
- Modify: `Scripts/test-karaoke-lyrics-rendering.sh:1-20`

**Interfaces:**
- Consumes: `KaraokeLyricText` and `KaraokeFontWeight.bold` from Task 4.
- Produces: KSC highlighting in every surface that hosts `TrackLyricsContent`.

- [ ] **Step 1: Extend the renderer check with a failing shared-view integration guard**

Add before the typecheck command in `Scripts/test-karaoke-lyrics-rendering.sh`:

```bash
TRACK_VIEW="$ROOT_DIR/Views/Main/TrackLyricsView.swift"
rg -n 'KaraokeLyricText\(' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must render timed KSC lines with KaraokeLyricText.\n' >&2
    exit 1
}
rg -n 'sampledPlaybackTime = newTime' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must anchor the renderer from published playback samples.\n' >&2
    exit 1
}
```

- [ ] **Step 2: Run the renderer check and confirm RED**

Run: `Scripts/test-karaoke-lyrics-rendering.sh`

Expected: it fails with `TrackLyricsContent must render timed KSC lines with KaraokeLyricText.`

- [ ] **Step 3: Capture published playback samples in view state**

Add to `TrackLyricsContent`:

```swift
@State private var sampledPlaybackTime: TimeInterval = 0
```

Replace the current progress subscriber with:

```swift
.onReceive(playbackManager.playbackProgressState.$currentTime) { newTime in
    sampledPlaybackTime = newTime
    updateCurrentLine(for: newTime)
}
```

In the cached branch, replace the existing update call with:

```swift
sampledPlaybackTime = playbackManager.playbackProgressState.currentTime
updateCurrentLine(for: sampledPlaybackTime)
```

In the successful async `MainActor.run` block, after assigning `lyricLines`, `hasTimedLyrics`, `isLoading`, and `fetchFailed`, add the same two lines so a newly loaded KSC line renders immediately instead of waiting for the next 0.5-second sample.

- [ ] **Step 4: Route only the active timed KSC line through the shared renderer**

Replace the inline `Text` in the lyrics `ForEach` with `lyricRow(line:index:)`, retaining `.id(index)` on the returned row. Add:

```swift
@ViewBuilder
private func lyricRow(line: LyricLine, index: Int) -> some View {
    let isCurrent = hasTimedLyrics && currentLineIndex == index

    if isCurrent, line.timingSegments?.isEmpty == false {
        KaraokeLyricText(
            line: line,
            sampleTime: sampledPlaybackTime,
            isPlaying: playbackManager.isPlaying,
            fontSize: fontSize,
            fontWeight: .bold,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            lineSpacing: 6
        )
        .frame(maxWidth: .infinity)
        .scaleEffect(1.1)
        .multilineTextAlignment(.center)
    } else {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: fontSize))
            .fontWeight(isCurrent ? .bold : .regular)
            .scaleEffect(isCurrent ? 1.1 : 1.0)
            .foregroundColor(isCurrent ? activeColor : inactiveColor)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
    }
}
```

Do not change the `currentLineIndex` selection or animated `proxy.scrollTo`; mini player and immersive mode inherit the behavior because they already host `TrackLyricsContent`.

- [ ] **Step 5: Run integration, transition, timing, and Debug build checks**

Run:

```bash
Scripts/test-karaoke-lyrics-rendering.sh
Scripts/test-track-lyrics-highlight-transition.sh
Scripts/test-karaoke-timing.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: all scripts pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit the shared lyrics-surface integration**

```bash
git add Views/Main/TrackLyricsView.swift Scripts/test-karaoke-lyrics-rendering.sh
git commit -m "feat(lyrics): show word highlights in lyrics panels"
```

---

### Task 6: Desktop lyrics full-line model and karaoke rendering

**Files:**
- Modify: `Core/DesktopLyricsLineSelection.swift:3-65`
- Modify: `Views/DesktopLyrics/DesktopLyricsView.swift:4-130`
- Modify: `Scripts/test-desktop-lyrics-line-selection.sh:1-103`
- Modify: `Scripts/test-karaoke-lyrics-rendering.sh:1-30`

**Interfaces:**
- Consumes: `LyricLine`, `KaraokeLyricText`, and `KaraokeFontWeight.semibold`.
- Produces: `DesktopLyricsDisplayLines(current: LyricLine, next: LyricLine?)` and desktop KSC word highlighting.

- [ ] **Step 1: Change the desktop selection expectations first**

Change `DesktopLyricsDisplayLines` expectations in `Scripts/test-desktop-lyrics-line-selection.sh` to use the original line values. For example, the first assertion becomes:

```swift
assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 4),
    DesktopLyricsDisplayLines(current: timed[0], next: timed[2]),
    "synced lyrics select current line and next non-empty line"
)
```

Apply the same mapping to all expectations: at time 11 use `timed[2]`/`timed[3]`, before the first line use `timed[0]`/`timed[2]`, after 22 use `timed[3]`/`nil`, and plain lyrics use `plain[1]`/`plain[2]`.

Extend `Scripts/test-karaoke-lyrics-rendering.sh` with:

```bash
DESKTOP_VIEW="$ROOT_DIR/Views/DesktopLyrics/DesktopLyricsView.swift"
rg -n 'KaraokeLyricText\(' "$DESKTOP_VIEW" >/dev/null || {
    printf 'Desktop lyrics must render timed KSC lines with KaraokeLyricText.\n' >&2
    exit 1
}
```

- [ ] **Step 2: Run both checks and confirm RED**

Run: `Scripts/test-desktop-lyrics-line-selection.sh; Scripts/test-karaoke-lyrics-rendering.sh`

Expected: the selection check fails to compile because `DesktopLyricsDisplayLines` still accepts strings, and the rendering check reports the missing desktop integration.

- [ ] **Step 3: Preserve full lyric lines in desktop selection**

Change the display model to:

```swift
struct DesktopLyricsDisplayLines: Equatable {
    let current: LyricLine
    let next: LyricLine?
}
```

Return `lines[currentIndex]` and `lines[nextIndex]` directly from both selection methods. Keep `trimmedText` only for emptiness checks; do not rebuild `LyricLine`, because rebuilding would change identity and risk losing timing segments.

- [ ] **Step 4: Render the desktop current line with the shared component**

Add:

```swift
@State private var sampledPlaybackTime: TimeInterval = 0
```

In `.onAppear`, initialize it from `playbackProgressState.currentTime`. In the existing progress subscriber, assign the new sample before notifying the provider:

```swift
.onReceive(playbackProgressState.$currentTime) { currentTime in
    sampledPlaybackTime = currentTime
    provider.playbackTimeChanged(currentTime)
}
```

Replace `Text(lines.current)` with a helper call and change the next line to `Text(lines.next?.text ?? " ")`. Add:

```swift
@ViewBuilder
private func currentLyricsLine(_ line: LyricLine) -> some View {
    if line.timingSegments?.isEmpty == false {
        KaraokeLyricText(
            line: line,
            sampleTime: sampledPlaybackTime,
            isPlaying: playbackManager.isPlaying,
            fontName: desktopLyricsFontName == DesktopLyricsSettings.systemFontName ? nil : desktopLyricsFontName,
            fontSize: CGFloat(desktopLyricsFontSize),
            fontWeight: .semibold,
            activeColor: .primary,
            inactiveColor: .secondary,
            lineLimit: 1
        )
        .frame(maxWidth: .infinity)
    } else {
        Text(line.text)
            .font(currentLineFont)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
    }
}
```

Keep the existing outer horizontal padding and desktop text shadow so the AppKit-backed line receives the same window treatment.

- [ ] **Step 5: Run desktop, renderer, and build checks and confirm GREEN**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-karaoke-lyrics-rendering.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: both scripts pass and the build ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit desktop integration**

```bash
git add Core/DesktopLyricsLineSelection.swift Views/DesktopLyrics/DesktopLyricsView.swift Scripts/test-desktop-lyrics-line-selection.sh Scripts/test-karaoke-lyrics-rendering.sh
git commit -m "feat(lyrics): show word highlights in desktop lyrics"
```

---

### Task 7: KSC Trash sidecars and full regression verification

**Files:**
- Modify: `Core/TrackTrashSidecars.swift:3-24`
- Modify: `Scripts/test-track-trash-sidecars.sh:39-61`

**Interfaces:**
- Consumes: existing `TrackTrashSidecars.sidecarURLs(forAudioURL:fileManager:)`.
- Produces: `.ksc` membership in `TrackTrashSidecars.lyricExtensions` with unchanged artwork and fallback rules.

- [ ] **Step 1: Add the failing KSC Trash assertion**

After creating `Lonely.lrc` and `Lonely.srt` in `Scripts/test-track-trash-sidecars.sh`, add:

```swift
touch(root.appendingPathComponent("Lonely.ksc"))
```

Change the expected set to:

```swift
let expectedLonely: Set<String> = ["Lonely.ksc", "Lonely.lrc", "Lonely.srt", "cover.jpg"]
```

- [ ] **Step 2: Run the Trash check and confirm RED**

Run: `Scripts/test-track-trash-sidecars.sh`

Expected: it fails because `Lonely.ksc` is absent from the returned sidecars.

- [ ] **Step 3: Add KSC to the canonical lyric sidecar list**

Change the declaration in `Core/TrackTrashSidecars.swift` to:

```swift
static let lyricExtensions = ["ksc", "lrc", "srt"]
```

Do not change artwork detection, remaining-audio checks, security-scoped access, or Trash fallback code.

- [ ] **Step 4: Run the focused KSC/lyrics/Trash suite**

Run:

```bash
Scripts/test-lyrics-parsing.sh
Scripts/test-lyrics-sidecar-loading.sh
Scripts/test-karaoke-timing.sh
Scripts/test-karaoke-lyrics-rendering.sh
Scripts/test-lyrics-background-io.sh
Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-track-lyrics-highlight-transition.sh
Scripts/test-track-trash-sidecars.sh
```

Expected: all eight scripts exit 0 and print their success messages.

- [ ] **Step 5: Run the full shell regression suite**

Run:

```bash
for script in Scripts/test-*.sh; do
    "$script"
done
```

Expected: every repository shell check exits 0. If an unrelated pre-existing check fails, record its exact command and output, confirm the focused suite remains green, and do not change unrelated product code.

- [ ] **Step 6: Run the final Debug build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **` with no new warnings from the changed files.

- [ ] **Step 7: Inspect the final diff and commit**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD~6..HEAD
```

Expected: no whitespace errors; only the files listed in this plan are changed.

Commit the final Trash cycle:

```bash
git add Core/TrackTrashSidecars.swift Scripts/test-track-trash-sidecars.sh
git commit -m "feat(lyrics): trash KSC sidecars with tracks"
```

---

## Final Acceptance Checklist

- [ ] A valid same-name `.ksc` outranks `.lrc` and `.srt` and displays offline.
- [ ] Invalid KSC files fall through to LRC, SRT, then embedded lyrics.
- [ ] Valid timing counts produce smooth per-grapheme fill; invalid counts preserve line-level lyrics.
- [ ] Main, mini-player, immersive, and desktop lyrics all use the shared renderer.
- [ ] Pause freezes fill; resume, seek, and track change reset interpolation from the latest sample.
- [ ] LRC, SRT, plain embedded lyrics, line selection, scrolling, and existing highlight transitions remain unchanged.
- [ ] Same-name `.ksc` files follow the existing Trash and volume fallback behavior.
- [ ] Focused checks, the complete shell suite, and the Debug build pass.
