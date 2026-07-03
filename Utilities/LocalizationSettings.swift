import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let userDefaultsKey = "appLanguage"

    case system
    case english
    case simplifiedChinese

    var id: String {
        rawValue
    }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            "Follow System"
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            Locale.autoupdatingCurrent
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }

        return language
    }
}

@MainActor
final class LocalizationSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published private(set) var appLanguage: AppLanguage

    var locale: Locale {
        appLanguage.locale
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appLanguage = AppLanguage.stored(in: defaults)
    }

    func select(_ language: AppLanguage) {
        appLanguage = language
        defaults.set(language.rawValue, forKey: AppLanguage.userDefaultsKey)
    }
}
