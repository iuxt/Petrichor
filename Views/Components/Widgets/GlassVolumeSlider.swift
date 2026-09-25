import SwiftUI

/// Keep SwiftUI's system slider appearance, including Liquid Glass, while
/// handling track clicks separately from dragging the thumb.
struct GlassVolumeSlider: View {
    @Binding var value: Float
    let tint: Color
    var onInteractionStarted: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isPointerDown = false
    @State private var isDragging = false
    @State private var startedOnKnob = false
    @State private var dragOffset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .tint(tint)
                .frame(height: geometry.size.height)
                .highPriorityGesture(gesture(width: geometry.size.width))
        }
        .frame(height: 20)
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private func gesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !isPointerDown {
                    animationTask?.cancel()
                    animationTask = nil
                    isPointerDown = true
                    isDragging = false
                    onInteractionStarted?()

                    let knobCenter = xPosition(for: value, width: width)
                    startedOnKnob = abs(drag.startLocation.x - knobCenter) <= 12
                    dragOffset = startedOnKnob ? drag.startLocation.x - knobCenter : 0
                }

                if abs(drag.translation.width) > 3 || abs(drag.translation.height) > 3 {
                    if !isDragging {
                        isDragging = true
                        onEditingChanged?(true)
                    }
                    value = volume(at: drag.location.x - dragOffset, width: width)
                }
            }
            .onEnded { drag in
                isPointerDown = false
                if isDragging {
                    isDragging = false
                    onEditingChanged?(false)
                } else if !startedOnKnob {
                    animate(to: volume(at: drag.location.x, width: width))
                }
            }
    }

    private func xPosition(for volume: Float, width: CGFloat) -> CGFloat {
        10 + CGFloat(volume) * max(1, width - 20)
    }

    private func volume(at x: CGFloat, width: CGFloat) -> Float {
        Float(min(1, max(0, (x - 10) / max(1, width - 20))))
    }

    private func animate(to destination: Float) {
        let start = value
        guard abs(destination - start) > 0.001 else { return }

        animationTask = Task { @MainActor in
            let duration = 0.3
            var elapsed = 0.0
            var lastTick = ProcessInfo.processInfo.systemUptime
            while elapsed < duration {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                elapsed = min(duration, elapsed + min(now - lastTick, 1.0 / 30.0))
                lastTick = now
                let progress = Float(elapsed / duration)
                let eased = progress * progress * (3 - 2 * progress)
                value = start + (destination - start) * eased
            }
            animationTask = nil
        }
    }
}
