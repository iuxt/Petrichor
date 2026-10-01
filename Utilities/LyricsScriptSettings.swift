import Foundation
import SwiftUI

extension Notification.Name {
    static let lyricsScriptPreferenceDidChange = Notification.Name("lyricsScriptPreferenceDidChange")
}

/// Which writing script lyrics render in when a TTML carries more than one.
enum LyricsScriptPreference: String, CaseIterable, Identifiable {
    static let userDefaultsKey = "lyricsScriptPreference"

    case followAppLanguage
    case original
    case simplified
    case traditional

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .followAppLanguage:
            "Follow App Language"
        case .original:
            "Original Script"
        case .simplified:
            "Simplified Chinese"
        case .traditional:
            "Traditional Chinese"
        }
    }

    static func stored(in defaults: UserDefaults) -> LyricsScriptPreference {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let preference = LyricsScriptPreference(rawValue: rawValue) else {
            return .followAppLanguage
        }

        return preference
    }

    func resolvedScript(for appLanguage: AppLanguage) -> LyricScript {
        switch self {
        case .followAppLanguage:
            switch appLanguage.locale.language.script?.identifier {
            case "Hans": return .simplified
            case "Hant": return .traditional
            default: return .original
            }
        case .original:
            return .original
        case .simplified:
            return .simplified
        case .traditional:
            return .traditional
        }
    }
}

@MainActor
final class LyricsScriptSettings: ObservableObject {
    static let shared = LyricsScriptSettings()

    private let defaults: UserDefaults
    private var languageObserver: NSObjectProtocol?

    @Published private(set) var preference: LyricsScriptPreference

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preference = LyricsScriptPreference.stored(in: defaults)
        // Follow mode tracks the app language, so its resolution changes with it.
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.preference == .followAppLanguage else { return }
                NotificationCenter.default.post(name: .lyricsScriptPreferenceDidChange, object: nil)
            }
        }
    }

    deinit {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    /// The script lyrics should render in right now, with follow mode resolved.
    var effectiveScript: LyricScript {
        preference.resolvedScript(for: AppLanguage.stored(in: defaults))
    }

    func select(_ preference: LyricsScriptPreference) {
        guard preference != self.preference else { return }
        defaults.set(preference.rawValue, forKey: LyricsScriptPreference.userDefaultsKey)
        self.preference = preference
        NotificationCenter.default.post(name: .lyricsScriptPreferenceDidChange, object: preference)
    }
}
