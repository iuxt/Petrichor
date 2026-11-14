import Foundation

class FolderNode: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let name: String
    let isWatchFolder: Bool // True if this is the root watch folder

    @Published var children: [FolderNode] = []
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false

    // Counts for immediate contents only
    var immediateTrackCount: Int = 0
    var displayTrackCount: Int = 0
    var immediateFolderCount: Int {
        children.count
    }

    // Cached database folder reference if this corresponds to a watched folder
    var databaseFolder: Folder?

    init(url: URL, name: String? = nil, isWatchFolder: Bool = false) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isWatchFolder = isWatchFolder
    }

}

// Make it Equatable for selection tracking
extension FolderNode: Equatable {
    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.id == rhs.id
    }
}

// Make it Hashable for use in Sets
extension FolderNode: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
