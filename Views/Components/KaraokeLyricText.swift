import AppKit
import Foundation
import SwiftUI

enum KaraokeFontWeight: Equatable {
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
        .onChange(of: isPlaying) { _, playing in
            anchor = anchor.reanchored(at: clock.now, isPlaying: playing, upperBound: line.endTime)
        }
        .onChange(of: line.id) { _, _ in resetAnchor(time: sampleTime, playing: isPlaying) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.text))
    }

    private func resetAnchor(time: TimeInterval, playing: Bool) {
        anchor = KaraokePlaybackTimeAnchor(sampleTime: time, sampleInstant: clock.now, isPlaying: playing)
    }
}

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

    func makeNSView(context: Context) -> KaraokeTextRendererView {
        let view = KaraokeTextRendererView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: KaraokeTextRendererView, context: Context) {
        update(nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: KaraokeTextRendererView,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize(forWidth: max(1, proposal.width ?? 1))
    }

    private func update(_ view: KaraokeTextRendererView) {
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

struct KaraokeGlyphCluster {
    let characterRange: NSRange
    let glyphRange: NSRange
    let segmentIndices: [Int]

    func fillFraction(
        segments: [LyricTimingSegment],
        fillFractions: [Double]
    ) -> Double {
        var completedDuration = 0.0
        var totalDuration = 0.0

        for index in segmentIndices where segments.indices.contains(index) && fillFractions.indices.contains(index) {
            let duration = segments[index].duration
            guard duration.isFinite, duration > 0 else { continue }
            totalDuration += duration
            completedDuration += duration * min(1, max(0, fillFractions[index]))
        }

        if totalDuration > 0 {
            return min(1, max(0, completedDuration / totalDuration))
        }
        return segmentIndices.allSatisfy {
            fillFractions.indices.contains($0) && fillFractions[$0] >= 1
        } ? 1 : 0
    }
}

enum KaraokeGlyphClusterLayout {
    static func clusters(
        for line: LyricLine,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [KaraokeGlyphCluster]? {
        guard let segments = line.timingSegments, !segments.isEmpty else { return nil }
        layoutManager.ensureLayout(for: textContainer)

        var clusters: [KaraokeGlyphCluster] = []
        var startIndex = line.text.startIndex
        for (segmentIndex, segment) in segments.enumerated() {
            guard let endIndex = line.text.index(
                startIndex,
                offsetBy: segment.text.count,
                limitedBy: line.text.endIndex
            ), String(line.text[startIndex..<endIndex]) == segment.text else {
                return nil
            }

            let characterRange = NSRange(startIndex..<endIndex, in: line.text)
            startIndex = endIndex
            var actualCharacterRange = NSRange(location: NSNotFound, length: 0)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: &actualCharacterRange
            )
            guard actualCharacterRange.location != NSNotFound,
                  actualCharacterRange.length > 0,
                  glyphRange.location != NSNotFound,
                  glyphRange.length > 0 else {
                return nil
            }

            if let last = clusters.last,
               last.characterRange == actualCharacterRange,
               last.glyphRange == glyphRange {
                clusters[clusters.count - 1] = KaraokeGlyphCluster(
                    characterRange: last.characterRange,
                    glyphRange: last.glyphRange,
                    segmentIndices: last.segmentIndices + [segmentIndex]
                )
            } else {
                clusters.append(KaraokeGlyphCluster(
                    characterRange: actualCharacterRange,
                    glyphRange: glyphRange,
                    segmentIndices: [segmentIndex]
                ))
            }
        }

        guard startIndex == line.text.endIndex else { return nil }
        return clusters
    }
}

final class KaraokeTextRendererView: NSView {
    private struct Configuration {
        let line: LyricLine
        let fontName: String?
        let fontSize: CGFloat
        let fontWeight: KaraokeFontWeight
        let activeColor: NSColor
        let inactiveColor: NSColor
        let lineLimit: Int
        let lineSpacing: CGFloat

        func matches(_ other: Configuration) -> Bool {
            line == other.line
                && fontName == other.fontName
                && fontSize == other.fontSize
                && fontWeight == other.fontWeight
                && activeColor.isEqual(other.activeColor)
                && inactiveColor.isEqual(other.inactiveColor)
                && lineLimit == other.lineLimit
                && lineSpacing == other.lineSpacing
        }
    }

    private let baseStorage = NSTextStorage()
    private let baseLayout = NSLayoutManager()
    private let baseContainer = NSTextContainer(size: .zero)
    private let activeStorage = NSTextStorage()
    private let activeLayout = NSLayoutManager()
    private let activeContainer = NSTextContainer(size: .zero)

    private var line = LyricLine(text: "", startTime: 0)
    private var fillFractions: [Double] = []
    private var configuration: Configuration?
    private var glyphClusters: [KaraokeGlyphCluster]?
    private var needsGlyphClusterRebuild = true

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
        let newFillFractions = fillFractions
        let newConfiguration = Configuration(
            line: line,
            fontName: fontName,
            fontSize: fontSize,
            fontWeight: fontWeight,
            activeColor: NSColor(activeColor),
            inactiveColor: NSColor(inactiveColor),
            lineLimit: lineLimit,
            lineSpacing: lineSpacing
        )

        if let configuration, configuration.matches(newConfiguration) {
            if self.fillFractions != newFillFractions {
                self.fillFractions = newFillFractions
                needsDisplay = true
            }
            return
        }

        configuration = newConfiguration
        self.line = line
        self.fillFractions = newFillFractions

        let font = makeFont(name: fontName, size: fontSize, weight: fontWeight.nsWeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = lineLimit == 1 ? .byTruncatingTail : .byWordWrapping

        baseStorage.setAttributedString(NSAttributedString(
            string: line.text,
            attributes: [
                .font: font,
                .foregroundColor: newConfiguration.inactiveColor,
                .paragraphStyle: paragraph,
            ]
        ))
        activeStorage.setAttributedString(NSAttributedString(
            string: line.text,
            attributes: [
                .font: font,
                .foregroundColor: newConfiguration.activeColor,
                .paragraphStyle: paragraph,
            ]
        ))

        for container in [baseContainer, activeContainer] {
            container.maximumNumberOfLines = lineLimit
            container.lineBreakMode = paragraph.lineBreakMode
        }
        updateContainerWidth(max(1, bounds.width))
        glyphClusters = nil
        needsGlyphClusterRebuild = true
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

        if needsGlyphClusterRebuild {
            glyphClusters = KaraokeGlyphClusterLayout.clusters(
                for: line,
                layoutManager: activeLayout,
                textContainer: activeContainer
            )
            needsGlyphClusterRebuild = false
        }

        guard let clusters = glyphClusters else {
            activeLayout.drawGlyphs(forGlyphRange: baseGlyphs, at: origin)
            return
        }

        var completedGlyphRanges: [NSRange] = []
        var partialCluster: (cluster: KaraokeGlyphCluster, fraction: Double)?
        for cluster in clusters {
            let fraction = cluster.fillFraction(segments: segments, fillFractions: fillFractions)
            if fraction >= 1, partialCluster == nil {
                if let last = completedGlyphRanges.last,
                   NSMaxRange(last) == cluster.glyphRange.location {
                    completedGlyphRanges[completedGlyphRanges.count - 1] = NSUnionRange(last, cluster.glyphRange)
                } else {
                    completedGlyphRanges.append(cluster.glyphRange)
                }
            } else if fraction > 0, partialCluster == nil {
                partialCluster = (cluster, fraction)
            }
        }

        for glyphRange in completedGlyphRanges {
            activeLayout.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        }

        if let partialCluster {
            var clipRect = activeLayout.boundingRect(
                forGlyphRange: partialCluster.cluster.glyphRange,
                in: activeContainer
            )
            clipRect.origin.x += origin.x
            clipRect.origin.y += origin.y
            clipRect.size.width *= CGFloat(partialCluster.fraction)
            if clipRect.width > 0, clipRect.height > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: clipRect).addClip()
                activeLayout.drawGlyphs(
                    forGlyphRange: partialCluster.cluster.glyphRange,
                    at: origin
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func updateContainerWidth(_ width: CGFloat) {
        let size = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        guard baseContainer.containerSize != size || activeContainer.containerSize != size else {
            return
        }
        baseContainer.containerSize = size
        activeContainer.containerSize = size
        glyphClusters = nil
        needsGlyphClusterRebuild = true
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
