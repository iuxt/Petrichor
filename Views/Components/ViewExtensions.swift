import SwiftUI

// MARK: - Conditional Modifier

extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Adaptive Button Styles

extension View {
    @ViewBuilder
    func adaptiveButtonStyle(prominent: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                self.foregroundStyle(Color.accentColor)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else {
                self.foregroundStyle(.secondary)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        } else {
            self.legacyAdaptiveButtonStyle(prominent: prominent)
        }
#else
        self.legacyAdaptiveButtonStyle(prominent: prominent)
#endif
    }

    @ViewBuilder
    func adaptiveCircularButtonStyle() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            self.legacyAdaptiveCircularButtonStyle()
        }
#else
        self.legacyAdaptiveCircularButtonStyle()
#endif
    }

    @ViewBuilder
    private func legacyAdaptiveButtonStyle(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            self.buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func legacyAdaptiveCircularButtonStyle() -> some View {
        self.buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
    }

    /// Backdrop behind a floating control cluster so glyphs stay legible over artwork.
    @ViewBuilder
    func floatingControlClusterBackground() -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            legacyFloatingControlClusterBackground()
        }
#else
        legacyFloatingControlClusterBackground()
#endif
    }

    private func legacyFloatingControlClusterBackground() -> some View {
        background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().fill(.black.opacity(0.12)))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        )
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func adaptiveSharedBackgroundHidden() -> some ToolbarContent {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
#else
        self
#endif
    }
}

// MARK: - Lossless Label

/// A glyph + "Lossless" label, shared between the track-detail view and the
/// player's format badges. Defaults match the track-detail sizing; the player
/// passes a more compact configuration.
struct LosslessLabel: View {
    var iconSize: CGFloat = 14
    var font: Font = .subheadline
    var spacing: CGFloat = 5

    var body: some View {
        HStack(spacing: spacing) {
            Image(Icons.customLossless)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundColor(.secondary)

            Text("Lossless")
                .font(font)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Gradient Background

struct GradientBackground: View {
    let colors: [Color]

    var body: some View {
        if #available(macOS 15.0, *), colors.count >= 6 {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    colors[0], colors[1], colors[2],
                    colors[3], colors[4], colors[5],
                    colors[2], colors[0], colors[3]
                ]
            )
            .overlay(.ultraThinMaterial)
        } else {
            GeometryReader { geometry in
                RadialGradient(
                    colors: colors + [.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: geometry.size.width
                )
                .overlay(.ultraThinMaterial)
            }
        }
    }
}
