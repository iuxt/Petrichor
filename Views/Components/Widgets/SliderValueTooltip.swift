import SwiftUI

/// A value bubble anchored to a slider's tracking position.
///
/// The view stays laid out while hidden, so revealing it during tracking
/// never animates it in from a newly inserted view's initial origin, and
/// animations are disabled for the whole tooltip subtree so it always
/// follows the drag immediately.
struct SliderValueTooltip: View, Equatable {
    enum Format: Equatable {
        /// 0...1 → "83%"
        case percent
        /// -12...12 → "6 dB"
        case decibels
    }

    let value: Float
    let format: Format
    let visible: Bool
    var isVertical = false

    var body: some View {
        GeometryReader { geo in
            Text(formattedText)
                .font(.caption)
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 2)
                )
                .fixedSize()
                .position(x: xAnchor(in: geo.size), y: yAnchor(in: geo.size))
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private var formattedText: String {
        switch format {
        case .percent:
            return value.formatted(.percent.precision(.fractionLength(0)))
        case .decibels:
            return "\(Int(value)) dB"
        }
    }

    private var normalized: CGFloat {
        switch format {
        case .percent:
            return CGFloat(value)
        case .decibels:
            return CGFloat((value + 12) / 24)
        }
    }

    private func xAnchor(in size: CGSize) -> CGFloat {
        isVertical ? size.width / 2 : size.width * normalized
    }

    private func yAnchor(in size: CGSize) -> CGFloat {
        isVertical
            ? size.height * (1 - normalized) - 30
            : size.height / 2 - 25
    }

    // Only re-render when the displayed value actually changes, so parent
    // body re-evaluations while hidden cost nothing.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visible == rhs.visible
            && lhs.displayedValue == rhs.displayedValue
            && lhs.format == rhs.format
            && lhs.isVertical == rhs.isVertical
    }

    private var displayedValue: Int {
        switch format {
        case .percent:
            return Int((value * 100).rounded())
        case .decibels:
            return Int(value)
        }
    }
}
