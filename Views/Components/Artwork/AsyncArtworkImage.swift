import AppKit
import SwiftUI

struct AsyncArtworkImage<Placeholder: View>: View {
    let request: ArtworkRequest?
    let contentMode: ContentMode
    let onDataLoaded: ((Data?) -> Void)?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var artworkRevision = 0

    init(
        request: ArtworkRequest?,
        contentMode: ContentMode = .fill,
        onDataLoaded: ((Data?) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.request = request
        self.contentMode = contentMode
        self.onDataLoaded = onDataLoaded
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskID) { [expectedTaskID = taskID] in
            await loadArtwork(expectedTaskID: expectedTaskID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadedArtworkDidChange)) { notice in
            guard let savedAudioURL = notice.object as? URL, let request,
                  request.audioURL.deletingLastPathComponent().standardizedFileURL ==
                    savedAudioURL.deletingLastPathComponent().standardizedFileURL else { return }
            artworkRevision += 1
        }
    }

    private var taskID: String {
        guard let request else { return "nil" }
        return "\(request.kind.rawValue)-\(request.identity)-\(request.audioURL.path)-\(artworkRevision)"
    }

    @MainActor
    private func loadArtwork(expectedTaskID: String) async {
        guard !Task.isCancelled, expectedTaskID == taskID else { return }

        guard let request else {
            image = nil
            onDataLoaded?(nil)
            return
        }

        image = nil
        let data = await ArtworkResolver.shared.artworkData(for: request)
        guard !Task.isCancelled, expectedTaskID == taskID else { return }

        image = data.flatMap(NSImage.init(data:))
        onDataLoaded?(data)
    }
}
