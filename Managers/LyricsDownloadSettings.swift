import Combine
import Foundation

enum LyricsSearchSource: String, CaseIterable, Identifiable, Sendable {
    case amll
    case netease
    case qqMusic

    var id: Self { self }

    var displayName: String {
        switch self {
        case .amll: "AMLL"
        case .netease: String(appLocalized: "NetEase Cloud Music")
        case .qqMusic: String(appLocalized: "QQ Music")
        }
    }

    var tagProvider: OnlineTagProvider? {
        switch self {
        case .amll: nil
        case .netease: .netease
        case .qqMusic: .qqMusic
        }
    }
}

@MainActor
final class LyricsDownloadSettings: ObservableObject {
    static let shared = LyricsDownloadSettings()
    @Published var automaticallyDownload: Bool {
        didSet { defaults.set(automaticallyDownload, forKey: "lyricsAutoDownload") }
    }
    @Published var automaticallyDownloadArtwork: Bool {
        didSet { defaults.set(automaticallyDownloadArtwork, forKey: "artworkAutoDownload") }
    }
    @Published var source: LyricsSearchSource {
        didSet { defaults.set(source.rawValue, forKey: "lyricsDownloadSource") }
    }
    @Published var includeTranslation: Bool {
        didSet { defaults.set(includeTranslation, forKey: "lyricsDownloadTranslation") }
    }
    @Published var artworkSource: OnlineTagProvider {
        didSet { defaults.set(artworkSource.rawValue, forKey: "artworkDownloadSource") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyDownload = defaults.bool(forKey: "lyricsAutoDownload")
        // Do not extend an existing lyrics-only permission to artwork downloads.
        automaticallyDownloadArtwork = defaults.bool(forKey: "artworkAutoDownload")
        source = LyricsSearchSource(rawValue: defaults.string(forKey: "lyricsDownloadSource") ?? "") ?? .amll
        includeTranslation = defaults.object(forKey: "lyricsDownloadTranslation") as? Bool ?? true
        artworkSource = OnlineTagProvider(rawValue: defaults.string(forKey: "artworkDownloadSource") ?? "") ?? .netease
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

@MainActor
enum LyricsDownloadNotice {
    static func success(_ savedURL: URL, for audioURL: URL) {
        NotificationManager.shared.addMessage(.info, String.localizedStringWithFormat(
            String(appLocalized: "Lyrics downloaded for %1$@: %2$@"),
            audioURL.lastPathComponent, savedURL.lastPathComponent
        ))
    }

    static func failure(for audioURL: URL, reason: String) {
        NotificationManager.shared.addMessage(.error, String.localizedStringWithFormat(
            String(appLocalized: "Could not download lyrics for %1$@: %2$@"),
            audioURL.lastPathComponent, reason
        ))
    }
}
