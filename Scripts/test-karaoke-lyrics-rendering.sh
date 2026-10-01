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

// Immersive hosts override centered text with leading alignment. Verify both
// the drawing position and cache invalidation when switching alignment.
func renderedTextOrigin(_ alignment: NSTextAlignment?) -> Int {
    renderer.configure(
        line: ligatureLine,
        fillFractions: [1, 1],
        fontName: "Helvetica",
        fontSize: 48,
        fontWeight: .regular,
        activeColor: .red,
        inactiveColor: .gray,
        lineLimit: 1,
        lineSpacing: 0,
        textAlignment: alignment
    )
    renderer.layoutSubtreeIfNeeded()
    guard let bitmap = renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds) else {
        fatalError("Could not create karaoke renderer bitmap")
    }
    renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               color.alphaComponent > 0.5,
               color.redComponent - color.greenComponent > 0.4 {
                return x
            }
        }
    }
    fatalError("Karaoke renderer produced no highlighted text")
}

let centeredOrigin = renderedTextOrigin(nil)
let leadingOrigin = renderedTextOrigin(.left)
let restoredOrigin = renderedTextOrigin(nil)
precondition(leadingOrigin < centeredOrigin - 50,
             "The immersive alignment override must move text to the leading edge")
precondition(restoredOrigin == centeredOrigin,
             "Removing the override must restore the line's original alignment")
print("Karaoke immersive alignment checks passed")

assertClose(KaraokeWordLift.fraction(for: -1), 0, "Unstarted words stay on the baseline")
assertClose(KaraokeWordLift.fraction(for: 0.5), 0.5, "Words ease upward as they fill")
assertClose(KaraokeWordLift.fraction(for: 2), 1, "Completed words hold their raised position")

let liftRenderer = KaraokeTextRendererView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
let liftLine = LyricLine(text: "HH", startTime: 0, endTime: 2, timingSegments: [
    LyricTimingSegment(text: "H", startOffset: 0, duration: 1),
    LyricTimingSegment(text: "H", startOffset: 1, duration: 1)
])

func liftBitmap(_ fractions: [Double], reduceMotion: Bool = false) -> NSBitmapImageRep {
    liftRenderer.configure(
        line: liftLine, fillFractions: fractions, fontName: "Menlo", fontSize: 48,
        fontWeight: .regular, activeColor: .red, inactiveColor: .green,
        lineLimit: 0, lineSpacing: 0, textAlignment: .left,
        usesWordLift: true, reduceMotion: reduceMotion
    )
    liftRenderer.layoutSubtreeIfNeeded()
    let bitmap = liftRenderer.bitmapImageRepForCachingDisplay(in: liftRenderer.bounds)!
    liftRenderer.cacheDisplay(in: liftRenderer.bounds, to: bitmap)
    return bitmap
}

func glyphTop(_ bitmap: NSBitmapImageRep, first: Bool, active: Bool) -> Double {
    let scale = Double(bitmap.pixelsWide) / liftRenderer.bounds.width
    let xRange = first ? 0..<Int(28 * scale) : Int(30 * scale)..<Int(58 * scale)
    for y in 0..<bitmap.pixelsHigh {
        for x in xRange {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  color.alphaComponent > 0.5 else { continue }
            let isTarget = active ? color.redComponent - color.greenComponent > 0.4
                : color.greenComponent - color.redComponent > 0.2
            if isTarget { return Double(y) / scale }
        }
    }
    fatalError("Could not find the requested lifted glyph")
}

let beforeLift = liftBitmap([0, 0])
let firstBaseline = glyphTop(beforeLift, first: true, active: false)
let secondBaseline = glyphTop(beforeLift, first: false, active: false)
let liftSize = liftRenderer.intrinsicContentSize
liftRenderer.needsLayout = false
storageEditNotifications = 0
let liftStorageObserver = NotificationCenter.default.addObserver(
    forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil
) { _ in storageEditNotifications += 1 }
let firstLifted = liftBitmap([1, 0])
NotificationCenter.default.removeObserver(liftStorageObserver)
let firstRaisedTop = glyphTop(firstLifted, first: true, active: true)
precondition(firstRaisedTop <= firstBaseline - 2,
             "A completed word must move up by a few points")
assertClose(glyphTop(firstLifted, first: false, active: false), secondBaseline,
            "The upcoming word must remain on its original baseline")
precondition(storageEditNotifications == 0 && !liftRenderer.needsLayout,
             "Word lift frames must redraw without rebuilding TextKit layout")
precondition(liftRenderer.intrinsicContentSize == liftSize,
             "Word lift must not change line height while singing")

let completedLine = liftBitmap([1, 1])
assertClose(glyphTop(completedLine, first: true, active: true),
            glyphTop(completedLine, first: false, active: true),
            "The completed line must end on a uniform raised baseline")
let seekBack = liftBitmap([0, 0])
assertClose(glyphTop(seekBack, first: true, active: false), firstBaseline,
            "Seeking backward must reset the word position")
let reducedMotion = liftBitmap([1, 0], reduceMotion: true)
precondition(abs(glyphTop(reducedMotion, first: true, active: true) - firstBaseline) <= 0.75,
             "Reduce Motion must disable word lift (allowing color antialiasing differences)")

// Render a single timing segment that spans three visual lines. Its first
// fragment must fill before later fragments, with no text clipped at the top.
let wrappedLine = LyricLine(text: "HH HH HH", startTime: 0, endTime: 2, timingSegments: [
    LyricTimingSegment(text: "HH HH HH", startOffset: 0, duration: 2)
])
liftRenderer.setFrameSize(NSSize(width: 80, height: 240))
liftRenderer.configure(
    line: wrappedLine, fillFractions: [0.4], fontName: "Menlo", fontSize: 48,
    fontWeight: .regular, activeColor: .red, inactiveColor: .green,
    lineLimit: 0, lineSpacing: 6, textAlignment: .left, usesWordLift: true
)
liftRenderer.layoutSubtreeIfNeeded()
let wrappedBitmap = liftRenderer.bitmapImageRepForCachingDisplay(in: liftRenderer.bounds)!
liftRenderer.cacheDisplay(in: liftRenderer.bounds, to: wrappedBitmap)
var redRows: [Int] = []
var greenRows: [Int] = []
for y in 0..<wrappedBitmap.pixelsHigh {
    for x in 0..<wrappedBitmap.pixelsWide {
        guard let color = wrappedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              color.alphaComponent > 0.5 else { continue }
        if color.redComponent - color.greenComponent > 0.4 { redRows.append(y) }
        if color.greenComponent - color.redComponent > 0.2 { greenRows.append(y) }
    }
}
precondition(!redRows.isEmpty && !greenRows.isEmpty, "Wrapped text must retain both lyric colors")
precondition(redRows.reduce(0, +) / redRows.count < greenRows.reduce(0, +) / greenRows.count,
             "Wrapped words must highlight their first visual line before later lines")
print("Karaoke word lift drawing checks passed")
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
