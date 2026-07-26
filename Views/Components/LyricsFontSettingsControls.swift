import AppKit
import SwiftUI

enum LyricsFontSettings {
    static let systemFontName = "System"
    static let fontSizeRange = 18.0...48.0

    static var availableFontFamilies: [String] {
        [systemFontName] + NSFontManager.shared.availableFontFamilies.sorted()
    }
}

struct LyricsFontSettingsControls: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    var body: some View {
        Group {
            Picker("Font", selection: $fontName) {
                ForEach(LyricsFontSettings.availableFontFamilies, id: \.self) { family in
                    Text(family == LyricsFontSettings.systemFontName ? String(appLocalized: "System Font") : family)
                        .tag(family)
                }
            }

            HStack {
                Slider(value: $fontSize, in: LyricsFontSettings.fontSizeRange, step: 1) {
                    Text("Size")
                }

                Text("\(Int(fontSize))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }
}
