import Foundation

enum LyricsSidecarWriter {
    static func sidecarURL(forAudioURL audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func write(_ lyrics: String, forAudioURL audioURL: URL) throws {
        let sidecarURL = sidecarURL(forAudioURL: audioURL)
        guard !FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        try lyrics.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }
}
