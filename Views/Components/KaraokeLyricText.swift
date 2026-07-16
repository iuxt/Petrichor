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
