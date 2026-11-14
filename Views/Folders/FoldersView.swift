import SwiftUI
import Foundation

struct FoldersView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var selectedFolderNode: FolderNode?
    @State private var selectedTrackID: UUID?
    @State private var folderLoadTask: Task<Void, Never>?
    @State private var folderTracks: [Track] = []
    @State private var trackTableSortOrder = [KeyPathComparator(\Track.title)]

    @AppStorage("trackTableRowSize")
    private var trackTableRowSize: TableRowSize = .expanded

    var body: some View {
        if !libraryManager.shouldShowMainUI {
            NoMusicEmptyStateView(context: .mainWindow)
        } else {
            folderTracksView
                .onChange(of: selectedFolderNode, initial: true) { _, newNode in
                    folderTracks = []
                    handleFolderNodeSelection(newNode)
                }
                .onDisappear { folderLoadTask?.cancel() }
                .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
                    handleFolderNodeSelection(selectedFolderNode)
                }
        }
    }

    // MARK: - Folder Tracks View

    private var folderTracksView: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderTracksHeader

            Divider()

            folderTracksContent
        }
    }

    @ViewBuilder private var folderTracksHeader: some View {
        if let node = selectedFolderNode {
            TrackListHeader(
                title: node.name,
                sortOrder: $trackTableSortOrder,
                tableRowSize: $trackTableRowSize,
                sortContext: .folder
            )
        } else {
            TrackListHeader(title: String(appLocalized: "Select a Folder"), trackCount: 0)
        }
    }

    private var folderTracksContent: some View {
        Group {
            if selectedFolderNode == nil {
                noFolderSelectedView
            } else if folderTracks.isEmpty {
                emptyFolderView
            } else {
                trackListView
            }
        }
    }

    // MARK: - Content Views

    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No Music Files")
                .font(.headline)

            Text("No playable music files found in this folder")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var trackListView: some View {
        TrackView(
            tracks: folderTracks,
            selectedTrackID: $selectedTrackID,
            playlistID: nil,
            entityID: nil,
            queueSource: .folder,
            sortOrder: $trackTableSortOrder,
            onPlayTrack: { track in
                if selectedFolderNode != nil {
                    // For hierarchical view, we need to play from the track list
                    playlistManager.playTrack(track, fromTracks: folderTracks)
                    selectedTrackID = track.id
                }
            },
            contextMenuItems: { tracks, _ in
                if let node = selectedFolderNode {
                    // Create context menu items for folder node
                    if let dbFolder = node.databaseFolder {
                        return TrackContextMenu.createMenuItems(
                            for: tracks,
                            playlistManager: playlistManager,
                            currentContext: .folder(dbFolder)
                        )
                    } else {
                        // For sub-folders, use library context
                        return TrackContextMenu.createMenuItems(
                            for: tracks,
                            playlistManager: playlistManager,
                            currentContext: .library
                        )
                    }
                } else {
                    return []
                }
            },
            sortContext: .folder
        )
    }

    private var noFolderSelectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: Icons.folder)
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("Select a Folder")
                .font(.headline)

            Text("Choose a folder from the list to view its music files")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Hierarchical Sidebar Helper Methods

    private func handleFolderNodeSelection(_ node: FolderNode?) {
        folderLoadTask?.cancel()
        guard let node else {
            folderTracks = []
            return
        }

        let path = node.url.standardizedFileURL.path
        let database = libraryManager.databaseManager
        folderLoadTask = Task {
            let tracks = await Task.detached(priority: .userInitiated) {
                database.getImmediateTracksForFolderPath(path)
            }.value
            guard !Task.isCancelled, selectedFolderNode == node else { return }
            folderTracks = tracks
        }
    }
}

#Preview {
    @Previewable @State var selectedFolderNode: FolderNode?

    FoldersView(selectedFolderNode: $selectedFolderNode)
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playbackManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.libraryManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playlistManager
        }())
        .frame(width: 800, height: 600)
}
