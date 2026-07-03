import AppKit
import SwiftUI

struct AsyncArtworkImage<Placeholder: View>: View {
    let request: ArtworkRequest?
    let contentMode: ContentMode
    let onDataLoaded: ((Data?) -> Void)?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

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
        .task(id: taskID) {
            await loadArtwork()
        }
    }

    private var taskID: String {
        guard let request else { return "nil" }
        return "\(request.kind.rawValue)-\(request.identity)-\(request.audioURL.path)"
    }

    private func loadArtwork() async {
        guard let request else {
            image = nil
            onDataLoaded?(nil)
            return
        }

        image = nil
        let data = await ArtworkResolver.shared.artworkData(for: request)
        guard !Task.isCancelled else { return }

        image = data.flatMap(NSImage.init(data:))
        onDataLoaded?(data)
    }
}
