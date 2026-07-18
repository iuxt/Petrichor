import AppKit
import SwiftUI

/// A native macOS checkbox that can display a batch field whose selected values differ.
///
/// SwiftUI's checkbox toggle has no public mixed-state binding. Keeping the bridge small
/// also ensures that a click always resolves the visual mixed state to a concrete value
/// before the editor marks the compilation field as changed.
struct MixedStateCheckbox: NSViewRepresentable {
    let title: String
    let value: Bool?
    let isEnabled: Bool
    let accessibilityLabel: String
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        button.allowsMixedState = true
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = isEnabled
        button.state = value.map { $0 ? .on : .off } ?? .mixed
        button.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.onChange = onChange
    }

    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func changed(_ sender: NSButton) {
            if sender.state == .mixed {
                sender.state = .on
            }
            onChange(sender.state == .on)
        }
    }
}
