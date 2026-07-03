import Foundation
import SwiftUI

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

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

    func localizationIdentifier(in bundle: Bundle) -> String? {
        switch self {
        case .system:
            return Bundle.preferredLocalizations(from: bundle.localizations).first
        case .english:
            return Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["en"]).first
        case .simplifiedChinese:
            return Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: ["zh-Hans", "zh"]).first
        }
    }
}

@MainActor
final class LocalizationSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published private(set) var appLanguage: AppLanguage

    nonisolated static var currentLanguage: AppLanguage {
        AppLanguage.stored()
    }

    nonisolated static func localizedBundle(for bundle: Bundle? = .main) -> Bundle {
        let baseBundle = bundle ?? .main
        guard let localizationIdentifier = currentLanguage.localizationIdentifier(in: baseBundle),
              let localizedBundleURL = baseBundle.url(forResource: localizationIdentifier, withExtension: "lproj"),
              let localizedBundle = Bundle(url: localizedBundleURL) else {
            return baseBundle
        }

        return localizedBundle
    }

    var locale: Locale {
        appLanguage.locale
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appLanguage = AppLanguage.stored(in: defaults)
    }

    func select(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        defaults.set(language.rawValue, forKey: AppLanguage.userDefaultsKey)
        appLanguage = language
        NotificationCenter.default.post(name: .appLanguageDidChange, object: language)
    }
}

extension String {
    init(
        appLocalized keyAndValue: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = .main,
        comment: StaticString? = nil
    ) {
        self.init(
            localized: keyAndValue,
            table: table,
            bundle: LocalizationSettings.localizedBundle(for: bundle),
            comment: comment
        )
    }
}
