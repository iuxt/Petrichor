import SwiftUI
import AppKit

/// A horizontal slider bridged to AppKit's NSSlider.
///
/// macOS 27's SwiftUI `Slider` is self-drawn (no NSSlider in the view tree)
/// and reveals a Liquid Glass tracking animation that slides the control in
/// from the window origin when pressed — layout-level modifiers can't touch
/// it because SwiftUI's layout stays frozen during the animation. Bridging
/// NSSlider directly, as the EQ sliders have always done, sidesteps the
/// rendering bug while keeping the native control's look and accessibility.
struct NativeSlider: NSViewRepresentable {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var tintColor: NSColor?
    /// Called with `true` as soon as the user adjusts the value and `false`
    /// shortly after the last change — NSSlider exposes no begin/end
    /// tracking callbacks, so the end is debounced.
    var onEditingChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: Double(value),
            minValue: Double(range.lowerBound),
            maxValue: Double(range.upperBound),
            target: context.coordinator,
            action: #selector(Coordinator.changed)
        )
        slider.controlSize = .small
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        // External writes (menu shortcuts, automation, state restore) must
        // not fight the user's in-flight drag.
        if !context.coordinator.isEditing {
            slider.doubleValue = Double(value)
        }
        slider.trackFillColor = tintColor
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: NativeSlider
        private(set) var isEditing = false

        init(_ parent: NativeSlider) {
            self.parent = parent
        }

        @objc
        func changed(_ sender: NSSlider) {
            isEditing = true
            parent.value = Float(sender.doubleValue)
            parent.onEditingChanged?(true)
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(stopEditing),
                object: nil
            )
            perform(#selector(stopEditing), with: nil, afterDelay: 0.15)
        }

        @objc
        private func stopEditing() {
            isEditing = false
            parent.onEditingChanged?(false)
        }
    }
}
