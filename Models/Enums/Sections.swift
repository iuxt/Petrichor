import Foundation

enum Sections: String, CaseIterable, Identifiable {
    case home
    case library
    case playlists
    case folders

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return String(appLocalized: "Home")
        case .library: return String(appLocalized: "Library")
        case .playlists: return String(appLocalized: "Playlists")
        case .folders: return String(appLocalized: "Folders")
        }
    }

    var icon: String {
        switch self {
        case .home: return Icons.musicNoteHouse
        case .library: return Icons.customMusicNoteRectangleStack
        case .playlists: return Icons.musicNoteList
        case .folders: return Icons.folder
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return Icons.musicNoteHouseFill
        case .library: return Icons.customMusicNoteRectangleStackFill
        case .playlists: return Icons.musicNoteList
        case .folders: return Icons.folderFill
        }
    }
}
