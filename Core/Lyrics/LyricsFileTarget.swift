import Foundation

/// Separates the real file granting access from the per-track sidecar name.
struct LyricsFileTarget: Sendable {
    let audioURL: URL
    let cueSheetURL: URL?
    let cueTrackNumber: Int?

    init(audioURL: URL, cueSheetURL: URL? = nil, cueTrackNumber: Int? = nil) {
        self.audioURL = audioURL
        self.cueSheetURL = cueSheetURL
        self.cueTrackNumber = cueTrackNumber
    }

    var anchorURL: URL { cueSheetURL ?? audioURL }
    var baseURL: URL {
        if let cueSheetURL, let cueTrackNumber {
            return cueSheetURL.appendingPathExtension(String(format: "track%02d", cueTrackNumber))
        }
        return audioURL.deletingPathExtension()
    }
    var lookupURL: URL { baseURL.appendingPathExtension("audio") }
    func destination(extension ext: String) -> URL { baseURL.appendingPathExtension(ext) }
}
