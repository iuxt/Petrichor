import Foundation

enum FilenameStem {
    static func fromURL(_ url: URL) -> String {
        fromFilename(url.lastPathComponent)
    }

    static func fromFilename(_ filename: String) -> String {
        guard let dotIndex = filename.lastIndex(of: "."),
              dotIndex != filename.startIndex else {
            return filename
        }

        return String(filename[..<dotIndex])
    }
}
