import AppKit
import SwiftUI

struct DesktopLyricsView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState

    @StateObject private var provider: DesktopLyricsLineProvider

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false

    @AppStorage("desktopLyricsFontName")
    private var desktopLyricsFontName = DesktopLyricsSettings.systemFontName

    @AppStorage("desktopLyricsFontSize")
    private var desktopLyricsFontSize = 28.0

    @State private var window: NSWindow?
    @State private var dragStartOrigin: CGPoint?
    @State private var dragStartMouse: CGPoint?
    @State private var sampledPlaybackTime: TimeInterval = 0

    init(provider: DesktopLyricsLineProvider) {
        _provider = StateObject(wrappedValue: provider)
    }

    var body: some View {
        content
            .frame(width: 560, height: 96)
            .background(background)
            .contentShape(Rectangle())
            .gesture(windowMoveGesture)
            .captureDesktopLyricsWindow { capturedWindow in
                window = capturedWindow
                DesktopLyricsWindowManager.shared.applyCurrentSettings()
            }
            .onAppear {
                sampledPlaybackTime = playbackProgressState.currentTime
                provider.appear()
            }
            .onDisappear {
                provider.disappear()
            }
            .onChange(of: desktopLyricsClickThrough) {
                DesktopLyricsWindowManager.shared.applyCurrentSettings()
            }
            .onChange(of: playbackManager.currentTrack?.id) {
                provider.currentTrackChanged()
            }
            .onChange(of: playbackManager.isPlaying) { _, isPlaying in
                provider.playbackStateChanged(isPlaying: isPlaying)
            }
            .onReceive(playbackProgressState.$currentTime) { currentTime in
                sampledPlaybackTime = currentTime
                provider.playbackTimeChanged(currentTime)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch provider.state {
        case .idle:
            statusText("Not Playing")
        case .loading:
            statusText("Loading lyrics")
        case .empty:
            statusText("No Lyrics Available")
        case .failed:
            statusText("Lyrics Failed to Load")
        case .lyrics(let lines):
            VStack(spacing: 8) {
                currentLyricsLine(lines.current)

                Text(lines.next?.text ?? " ")
                    .font(nextLineFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .textShadowForDesktopLyrics()
        }
    }

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

    private func statusText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(currentLineFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .textShadowForDesktopLyrics()
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.10))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
    }

    private var currentLineFont: Font {
        desktopFont(size: CGFloat(desktopLyricsFontSize), weight: .semibold)
    }

    private var nextLineFont: Font {
        desktopFont(size: CGFloat(desktopLyricsFontSize) * 0.85, weight: .regular)
    }

    private func desktopFont(size: CGFloat, weight: Font.Weight) -> Font {
        if desktopLyricsFontName == DesktopLyricsSettings.systemFontName {
            return .system(size: size, weight: weight)
        }
        return .custom(desktopLyricsFontName, size: size).weight(weight)
    }

    private var windowMoveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let window else { return }
                if dragStartOrigin == nil {
                    dragStartOrigin = window.frame.origin
                    dragStartMouse = NSEvent.mouseLocation
                }
                guard let startOrigin = dragStartOrigin, let startMouse = dragStartMouse else { return }
                let current = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + (current.x - startMouse.x),
                    y: startOrigin.y + (current.y - startMouse.y)
                ))
            }
            .onEnded { _ in
                dragStartOrigin = nil
                dragStartMouse = nil
                DesktopLyricsWindowManager.shared.saveFrame()
            }
    }
}

enum DesktopLyricsSettings {
    static let systemFontName = "System"
}

extension View {
    func captureDesktopLyricsWindow(_ onWindow: @escaping (NSWindow) -> Void) -> some View {
        background(DesktopLyricsWindowAccessor(onWindow: onWindow))
    }

    fileprivate func textShadowForDesktopLyrics() -> some View {
        shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
    }
}

private struct DesktopLyricsWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
