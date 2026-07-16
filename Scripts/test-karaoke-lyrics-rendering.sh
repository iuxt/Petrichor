#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Views/Components/KaraokeLyricText.swift"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

test -f "$SOURCE" || { printf 'Missing shared KaraokeLyricText component.\n' >&2; exit 1; }
rg -n 'struct KaraokeLyricText: View' "$SOURCE" >/dev/null
rg -n 'NSViewRepresentable' "$SOURCE" >/dev/null
rg -n 'NSLayoutManager' "$SOURCE" >/dev/null
rg -n 'final class KaraokeTextRendererView: NSView' "$SOURCE" >/dev/null || {
    printf 'The AppKit karaoke renderer must be isolated as a directly behavior-testable view.\n' >&2
    exit 1
}
rg -n 'TimelineView\(\.animation' "$SOURCE" >/dev/null
rg -n 'accessibilityLabel' "$SOURCE" >/dev/null
rg -n 'anchor = anchor\.reanchored' "$SOURCE" >/dev/null || {
    printf 'Karaoke playback-state transitions must preserve the interpolated anchor time.\n' >&2
    exit 1
}
if rg -n '\.ligature[[:space:]]*:[[:space:]]*0' "$SOURCE" >/dev/null; then
    printf 'Karaoke rendering must preserve font shaping instead of disabling ligatures.\n' >&2
    exit 1
fi
rg -n 'fineProgressSampling \? \.milliseconds\(500\) : \.seconds\(1\)' \
    "$ROOT_DIR/Managers/PlaybackManager.swift" >/dev/null || {
    printf 'Karaoke rendering must not raise the global playback timer frequency.\n' >&2
    exit 1
}

TRACK_VIEW="$ROOT_DIR/Views/Main/TrackLyricsView.swift"
rg -n 'KaraokeLyricText\(' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must render timed KSC lines with KaraokeLyricText.\n' >&2
    exit 1
}
rg -n 'sampledPlaybackTime = newTime' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must anchor the renderer from published playback samples.\n' >&2
    exit 1
}

DESKTOP_VIEW="$ROOT_DIR/Views/DesktopLyrics/DesktopLyricsView.swift"
rg -n 'KaraokeLyricText\(' "$DESKTOP_VIEW" >/dev/null || {
    printf 'Desktop lyrics must render timed KSC lines with KaraokeLyricText.\n' >&2
    exit 1
}

TRACK_BOUNDARY_SOURCE="$ROOT_DIR/Views/Main/TrackLyricsView.swift"
rg -n 'KaraokeLineBoundaryScheduler' "$TRACK_BOUNDARY_SOURCE" >/dev/null || {
    printf 'TrackLyricsContent must own a local KSC line-boundary scheduler.\n' >&2
    exit 1
}
rg -n 'boundaryScheduler\.(reset|transition|cancel)' "$TRACK_BOUNDARY_SOURCE" >/dev/null || {
    printf 'TrackLyricsContent must reset and cancel local KSC boundaries with playback state.\n' >&2
    exit 1
}

DESKTOP_PROVIDER="$ROOT_DIR/Views/DesktopLyrics/DesktopLyricsLineProvider.swift"
rg -n 'KaraokeLineBoundaryScheduler' "$DESKTOP_PROVIDER" >/dev/null || {
    printf 'Desktop lyrics must own a local KSC line-boundary scheduler.\n' >&2
    exit 1
}
rg -n 'boundaryScheduler\.(reset|transition|cancel)' "$DESKTOP_PROVIDER" >/dev/null || {
    printf 'Desktop lyrics must reset and cancel local KSC boundaries with playback state.\n' >&2
    exit 1
}

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import AppKit
import Foundation
import SwiftUI

func makeLayout(
    text: String,
    font: NSFont,
    width: CGFloat,
    lineLimit: Int
) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = lineLimit == 1 ? .byTruncatingTail : .byWordWrapping
    let storage = NSTextStorage(attributedString: NSAttributedString(
        string: text,
        attributes: [.font: font, .paragraphStyle: paragraph]
    ))
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = lineLimit
    container.lineBreakMode = paragraph.lineBreakMode
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    return (storage, layout, container)
}

func assertClose(_ actual: Double, _ expected: Double, _ message: String) {
    precondition(abs(actual - expected) < 0.0001, "\(message): expected \(expected), got \(actual)")
}

let ligatureText = "fi"
let ligatureLine = LyricLine(
    text: ligatureText,
    startTime: 0,
    endTime: 1,
    timingSegments: [
        LyricTimingSegment(text: "f", startOffset: 0, duration: 0.25),
        LyricTimingSegment(text: "i", startOffset: 0.25, duration: 0.75),
    ]
)
let (ligatureStorage, ligatureLayout, ligatureContainer) = makeLayout(
    text: ligatureText,
    font: NSFont(name: "Helvetica", size: 48)!,
    width: 300,
    lineLimit: 0
)
let ligatureClusters = KaraokeGlyphClusterLayout.clusters(
    for: ligatureLine,
    layoutManager: ligatureLayout,
    textContainer: ligatureContainer
)
withExtendedLifetime(ligatureStorage) {}
precondition(
    ligatureClusters?.count == 1,
    "Helvetica fi must be treated as one TextKit character/glyph cluster, got \(String(describing: ligatureClusters?.map { ($0.characterRange, $0.glyphRange) }))"
)
let ligatureCluster = ligatureClusters![0]
precondition(ligatureCluster.characterRange == NSRange(location: 0, length: 2),
             "Both ligature characters must share the expanded TextKit character range")
assertClose(
    ligatureCluster.fillFraction(segments: ligatureLine.timingSegments!, fillFractions: [1, 0]),
    0.25,
    "A shared ligature cluster must use duration-weighted progress"
)

let truncationText = "ABCDEFGHIJKLMNO"
let truncationSegments = truncationText.enumerated().map { index, character in
    LyricTimingSegment(text: String(character), startOffset: Double(index), duration: 1)
}
let truncationLine = LyricLine(
    text: truncationText,
    startTime: 0,
    endTime: Double(truncationSegments.count),
    timingSegments: truncationSegments
)
let (truncationStorage, truncationLayout, truncationContainer) = makeLayout(
    text: truncationText,
    font: NSFont(name: "Helvetica", size: 40)!,
    width: 110,
    lineLimit: 1
)
let truncationClusters = KaraokeGlyphClusterLayout.clusters(
    for: truncationLine,
    layoutManager: truncationLayout,
    textContainer: truncationContainer
)!
withExtendedLifetime(truncationStorage) {}
guard let truncatedTail = truncationClusters.first(where: { $0.characterRange.length > 1 }) else {
    fatalError("This platform did not expose the single-line truncation tail as a shared TextKit cluster")
}
var firstTailOnly = Array(repeating: 0.0, count: truncationSegments.count)
firstTailOnly[truncatedTail.segmentIndices[0]] = 1
let tailFraction = truncatedTail.fillFraction(
    segments: truncationSegments,
    fillFractions: firstTailOnly
)
assertClose(
    tailFraction,
    1 / Double(truncatedTail.segmentIndices.count),
    "A truncation cluster must not complete when only its first hidden character completes"
)

let renderer = KaraokeTextRendererView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
renderer.configure(
    line: ligatureLine,
    fillFractions: [0, 0],
    fontName: "Helvetica",
    fontSize: 48,
    fontWeight: .regular,
    activeColor: .red,
    inactiveColor: .gray,
    lineLimit: 1,
    lineSpacing: 0
)
renderer.layoutSubtreeIfNeeded()
let initialIntrinsicSize = renderer.intrinsicContentSize
renderer.needsLayout = false
var storageEditNotifications = 0
let storageObserver = NotificationCenter.default.addObserver(
    forName: NSTextStorage.didProcessEditingNotification,
    object: nil,
    queue: nil
) { _ in
    storageEditNotifications += 1
}
renderer.configure(
    line: ligatureLine,
    fillFractions: [0.5, 0],
    fontName: "Helvetica",
    fontSize: 48,
    fontWeight: .regular,
    activeColor: .red,
    inactiveColor: .gray,
    lineLimit: 1,
    lineSpacing: 0
)
NotificationCenter.default.removeObserver(storageObserver)
precondition(!renderer.needsLayout, "A fill-only frame update must not request TextKit relayout")
precondition(storageEditNotifications == 0,
             "A fill-only frame update must not edit either attributed text storage")
precondition(
    renderer.intrinsicContentSize == initialIntrinsicSize,
    "A fill-only frame update must preserve the cached intrinsic layout"
)

print("Karaoke TextKit cluster behavior checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$SOURCE" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/karaoke-renderer-test"

"$TMP_DIR/karaoke-renderer-test"

xcrun swiftc -typecheck \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$SOURCE"

printf 'Karaoke lyrics renderer checks passed\n'
