import Foundation

enum TrackTrashFallback {
    static let appTrashFolderName = "Petrichor"

    static func fallbackURL(for originalURL: URL, trashDirectory: URL, fileManager: FileManager = .default) -> URL {
        let appTrashDirectory = trashDirectory.appendingPathComponent(appTrashFolderName, isDirectory: true)
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension

        var candidate = appTrashDirectory.appendingPathComponent(originalURL.lastPathComponent)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let filename = ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
            candidate = appTrashDirectory.appendingPathComponent(filename)
            suffix += 1
        }

        return candidate
    }
}
