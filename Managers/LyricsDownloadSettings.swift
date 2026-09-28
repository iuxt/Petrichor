import Combine
import Foundation

@MainActor
final class LyricsDownloadSettings: ObservableObject {
    static let shared = LyricsDownloadSettings()
    @Published var automaticallyDownload: Bool {
        didSet { defaults.set(automaticallyDownload, forKey: "lyricsAutoDownload") }
    }
    @Published var provider: OnlineTagProvider {
        didSet { defaults.set(provider.rawValue, forKey: "lyricsDownloadProvider") }
    }
    @Published var includeTranslation: Bool {
        didSet { defaults.set(includeTranslation, forKey: "lyricsDownloadTranslation") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyDownload = defaults.bool(forKey: "lyricsAutoDownload")
        provider = OnlineTagProvider(rawValue: defaults.string(forKey: "lyricsDownloadProvider") ?? "") ?? .netease
        includeTranslation = defaults.object(forKey: "lyricsDownloadTranslation") as? Bool ?? true
    }
}

extension Notification.Name {
    static let downloadedLyricsDidChange = Notification.Name("DownloadedLyricsDidChange")
    static let searchLyricsOnline = Notification.Name("SearchLyricsOnline")
}

func lyricsDownloadMessage(for error: Error) -> String {
    switch error {
    case LyricsDownloadError.noLyrics:
        return String(appLocalized: "This result has no downloadable synchronized lyrics. Try another song or source.")
    case LyricsDownloadError.invalidResponse:
        return String(appLocalized: "The lyrics provider returned an unreadable response. Try another source.")
    case LyricsDownloadError.unsafeDestination:
        return String(appLocalized: "The lyrics destination is not a regular file. Choose another song or check the folder.")
    default:
        if (error as? URLError)?.code == .timedOut {
            return String(appLocalized: "The lyrics request timed out. Please try again.")
        }
        return String(appLocalized: "Could not download lyrics. Check your connection or try another source.")
    }
}
