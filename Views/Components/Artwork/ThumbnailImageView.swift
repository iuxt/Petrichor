import AppKit

/// A reusable, small image view. Its asynchronous task captures the view weakly
/// and is cancelled as soon as the containing table row is recycled.
@MainActor
final class ThumbnailImageView: NSView {
    private var request: ArtworkRequest?
    private var revision = 0
    private var image: NSImage?
    private var loadTask: Task<Void, Never>?
    private static let placeholder = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))

    override var intrinsicContentSize: NSSize {
        NSSize(width: ViewDefaults.listArtworkSize, height: ViewDefaults.listArtworkSize)
    }

    func configure(request: ArtworkRequest, revision: Int) {
        guard self.request != request || self.revision != revision else { startLoading(); return }
        stopLoading()
        self.request = request
        self.revision = revision
        startLoading()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLoading() } else { startLoading() }
    }

    func stopLoading() {
        loadTask?.cancel()
        loadTask = nil
        image = nil
        needsDisplay = true
    }

    private func startLoading() {
        guard window != nil, loadTask == nil, image == nil, let request else { return }
        let expectedRevision = revision
        loadTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
            let image = await TrackThumbnailCache.shared.image(for: request)
            guard !Task.isCancelled, let self,
                  self.request == request, self.revision == expectedRevision else { return }
            self.image = image
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).addClip()
        guard let image else {
            NSColor.gray.withAlphaComponent(0.2).setFill()
            bounds.fill()
            Self.placeholder?.draw(in: NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18))
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                             width: size.width, height: size.height))
    }
}
