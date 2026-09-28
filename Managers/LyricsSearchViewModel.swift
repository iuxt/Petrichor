import Combine
import Foundation

struct LyricsSearchRequest: Identifiable {
    let id = UUID()
    let track: Track
}

@MainActor
final class LyricsSearchViewModel: ObservableObject {
    let track: Track
    @Published var title: String { didSet { if title != oldValue { resetSearch() } } }
    @Published var artist: String { didSet { if artist != oldValue { resetSearch() } } }
    @Published var provider: OnlineTagProvider { didSet { if provider != oldValue { resetSearch() } } }
    @Published var includeTranslation: Bool { didSet { if includeTranslation != oldValue { clearPreview() } } }
    @Published var selection: String? { didSet { if selection != oldValue { clearPreview() } } }
    @Published private(set) var candidates: [OnlineTagCandidate] = []
    @Published private(set) var preview: DownloadedLyrics?
    @Published private(set) var isSearching = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasSearched = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedURL: URL?
    @Published var needsOverwriteConfirmation = false

    private let service: any OnlineLyricsServing
    private let writer: any DownloadedLyricsWriting
    private let didSave: @MainActor (URL) -> Void
    private var searchTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var previewGeneration = 0

    init(track: Track, settings: LyricsDownloadSettings? = nil,
         service: any OnlineLyricsServing = OnlineLyricsService(),
         writer: any DownloadedLyricsWriting = DownloadedLyricsFileStore.shared,
         didSave: @escaping @MainActor (URL) -> Void = { url in
             LyricsStore.shared.invalidate(for: url)
             NotificationCenter.default.post(name: .downloadedLyricsDidChange, object: url)
         }) {
        let settings = settings ?? .shared
        self.track = track
        title = track.title.isEmpty ? track.url.deletingPathExtension().lastPathComponent : track.title
        artist = track.artist == "Unknown Artist" ? "" : track.artist
        provider = settings.provider
        includeTranslation = settings.includeTranslation
        self.service = service
        self.writer = writer
        self.didSave = didSave
    }

    var selectedCandidate: OnlineTagCandidate? { candidates.first { $0.id == selection } }
    var canSearch: Bool {
        !isSearching && !isSaving && ![title, artist].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func search() {
        guard canSearch else { return }
        resetSearch()
        isSearching = true
        let generation = searchGeneration
        let service = service, provider = provider, title = title, artist = artist
        searchTask = Task { [weak self] in
            do {
                let result = try await service.search(provider: provider, title: title, artist: artist)
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                self.candidates = result
                self.isSearching = false
                self.hasSearched = true
            } catch {
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                self.isSearching = false
                self.hasSearched = true
                self.errorMessage = lyricsDownloadMessage(for: error)
            }
        }
    }

    func fetchPreview() {
        guard let candidate = selectedCandidate, !isSaving else { return }
        clearPreview()
        isDownloading = true
        let generation = previewGeneration
        let service = service, includeTranslation = includeTranslation
        downloadTask = Task { [weak self] in
            do {
                let lyrics = try await service.download(candidate, includeTranslation: includeTranslation)
                guard let self, !Task.isCancelled, self.previewGeneration == generation else { return }
                self.preview = lyrics
                self.isDownloading = false
            } catch {
                guard let self, !Task.isCancelled, self.previewGeneration == generation else { return }
                self.isDownloading = false
                self.errorMessage = lyricsDownloadMessage(for: error)
            }
        }
    }

    func save(overwrite: Bool = false) {
        guard let preview, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        needsOverwriteConfirmation = false
        Task {
            defer { isSaving = false }
            do {
                savedURL = try await writer.save(preview, for: track.url, overwrite: overwrite, automatic: false)
                didSave(track.url)
            } catch LyricsDownloadError.existingFile {
                needsOverwriteConfirmation = true
            } catch {
                errorMessage = String.localizedStringWithFormat(
                    String(appLocalized: "Could not save the LRC file. Check folder write access: %1$@"), error.localizedDescription
                )
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        downloadTask?.cancel()
        searchGeneration += 1
        previewGeneration += 1
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        isSearching = false
        hasSearched = false
        candidates = []
        selection = nil
        clearPreview()
    }

    private func clearPreview() {
        downloadTask?.cancel()
        previewGeneration += 1
        preview = nil
        savedURL = nil
        errorMessage = nil
        needsOverwriteConfirmation = false
        isDownloading = false
    }
}
