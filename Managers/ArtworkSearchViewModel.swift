import Combine
import Foundation

struct ArtworkSearchRequest: Identifiable {
    let id = UUID()
    let track: Track
}

@MainActor
final class ArtworkSearchViewModel: ObservableObject {
    let track: Track
    @Published var title: String { didSet { if title != oldValue { resetSearch() } } }
    @Published var artist: String { didSet { if artist != oldValue { resetSearch() } } }
    @Published var source: OnlineTagProvider { didSet { if source != oldValue { resetSearch() } } }
    @Published var selection: String? { didSet { if selection != oldValue { loadPreview() } } }
    @Published private(set) var candidates: [OnlineTagCandidate] = []
    @Published private(set) var previewData: Data?
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isSaving = false
    @Published private(set) var isCheckingArtwork = false
    @Published private(set) var hasSearched = false
    @Published private(set) var hasExistingArtwork = false
    @Published private(set) var savedURL: URL?
    @Published private(set) var errorMessage: String?
    @Published var needsOverwriteConfirmation = false

    private let searchService: any OnlineTagSearching
    private let artworkService: any OnlineArtworkServing
    private let writer: any DownloadedArtworkWriting
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var generation = 0

    init(track: Track,
         settings: LyricsDownloadSettings? = nil,
         searchService: any OnlineTagSearching = OnlineTagLookupService(),
         artworkService: any OnlineArtworkServing = OnlineArtworkService(),
         writer: any DownloadedArtworkWriting = DownloadedArtworkFileStore.shared) {
        self.track = track
        title = track.title
        artist = track.artist == "Unknown Artist" ? "" : track.artist
        source = (settings ?? .shared).artworkSource
        self.searchService = searchService
        self.artworkService = artworkService
        self.writer = writer
    }

    var selectedCandidate: OnlineTagCandidate? { candidates.first { $0.id == selection } }
    var canSearch: Bool {
        !isSearching && !isSaving && ![title, artist].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func checkLocalArtwork() {
        guard localTask == nil else { return }
        isCheckingArtwork = true
        let track = track
        localTask = Task { [weak self] in
            let request = ArtworkRequest.album(albumId: track.albumId,
                                               representativeTrackURL: track.url, albumTitle: track.album)
            let existing = await ArtworkResolver.shared.artworkData(for: request) != nil
            guard let self, !Task.isCancelled else { return }
            self.hasExistingArtwork = existing
            self.isCheckingArtwork = false
            self.localTask = nil
        }
    }

    func search() {
        guard canSearch else { return }
        resetSearch()
        isSearching = true
        let generation = generation, service = searchService
        let source = source, title = title, artist = artist
        searchTask = Task { [weak self] in
            do {
                let results = try await service.search(provider: source, title: title, artist: artist)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.candidates = results
                self.isSearching = false
                self.hasSearched = true
                self.searchTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.isSearching = false
                self.hasSearched = true
                self.searchTask = nil
                self.errorMessage = String(appLocalized: "Could not search for artwork. Check your connection and try again.")
            }
        }
    }

    func save(overwrite: Bool = false) {
        guard !isSaving, !isCheckingArtwork,
              savedURL == nil, let image = previewData else { return }
        if hasExistingArtwork && !overwrite {
            needsOverwriteConfirmation = true
            return
        }
        isSaving = true
        errorMessage = nil
        needsOverwriteConfirmation = false
        let generation = generation, writer = writer, audioURL = track.url
        saveTask = Task { [weak self] in
            defer {
                if let self, self.generation == generation {
                    self.isSaving = false
                    self.saveTask = nil
                }
            }
            do {
                let url = try await writer.saveManual(image, for: audioURL, overwrite: overwrite)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                ArtworkResolver.shared.invalidateMemoryCache()
                await TrackThumbnailCache.shared.removeAll()
                AppCoordinator.shared?.playbackManager.refreshCurrentTrackArtworkAfterDownload(for: audioURL)
                NotificationCenter.default.post(name: .downloadedArtworkDidChange, object: audioURL)
                self.savedURL = url
                NotificationManager.shared.addMessage(.info, String.localizedStringWithFormat(
                    String(appLocalized: "Artwork downloaded for %1$@: %2$@"),
                    audioURL.lastPathComponent, url.lastPathComponent
                ))
            } catch ArtworkDownloadError.existingArtwork {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.hasExistingArtwork = true
                self.needsOverwriteConfirmation = true
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                let message = String(appLocalized: "Could not save the selected artwork. Check folder write access.")
                self.errorMessage = message
                NotificationManager.shared.addMessage(.error, String.localizedStringWithFormat(
                    String(appLocalized: "Could not download artwork for %1$@: %2$@"),
                    audioURL.lastPathComponent, message
                ))
            }
        }
    }

    func cancel() {
        generation += 1
        searchTask?.cancel()
        previewTask?.cancel()
        saveTask?.cancel()
        localTask?.cancel()
    }

    private func loadPreview() {
        previewTask?.cancel()
        previewData = nil
        errorMessage = nil
        savedURL = nil
        needsOverwriteConfirmation = false
        isLoadingPreview = false
        guard let candidate = selectedCandidate else { return }
        let generation = generation, service = artworkService
        isLoadingPreview = true
        previewTask = Task { [weak self] in
            do {
                let data = try await service.download(for: candidate)
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.selection == candidate.id else { return }
                self.previewData = data
                self.isLoadingPreview = false
                self.previewTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.selection == candidate.id else { return }
                let message = String(appLocalized: "Could not load the selected artwork. Try another song or source.")
                self.errorMessage = message
                self.isLoadingPreview = false
                self.previewTask = nil
                NotificationManager.shared.addMessage(.error, String.localizedStringWithFormat(
                    String(appLocalized: "Could not download artwork for %1$@: %2$@"),
                    self.track.url.lastPathComponent, message
                ))
            }
        }
    }

    private func resetSearch() {
        generation += 1
        searchTask?.cancel()
        previewTask?.cancel()
        searchTask = nil
        previewTask = nil
        isSearching = false
        isLoadingPreview = false
        hasSearched = false
        candidates = []
        selection = nil
        previewData = nil
        errorMessage = nil
        needsOverwriteConfirmation = false
    }
}
