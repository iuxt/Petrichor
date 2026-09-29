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
    @Published var includeTranslation: Bool { didSet { if includeTranslation != oldValue { clearSaveState() } } }
    @Published var selection: String? { didSet { if selection != oldValue { clearSaveState() } } }
    @Published private(set) var candidates: [OnlineTagCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasSearched = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savedURL: URL?
    @Published var needsOverwriteConfirmation = false

    private let service: any OnlineLyricsServing
    private let writer: any DownloadedLyricsWriting
    private let didSave: @MainActor (URL) -> Void
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var saveGeneration = 0
    private var pendingOverwrite: DownloadedLyrics?

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

    func save(overwrite: Bool = false) {
        guard !isSaving, savedURL == nil else { return }
        guard let candidate = selectedCandidate, !overwrite || pendingOverwrite != nil else { return }
        isSaving = true
        errorMessage = nil
        needsOverwriteConfirmation = false
        let generation = saveGeneration
        let service = service, writer = writer, includeTranslation = includeTranslation
        saveTask = Task { [weak self] in
            var lyrics = overwrite ? self?.pendingOverwrite : nil
            defer {
                if let self, self.saveGeneration == generation {
                    self.isSaving = false
                    self.saveTask = nil
                }
            }
            do {
                if lyrics == nil {
                    lyrics = try await service.download(candidate, includeTranslation: includeTranslation)
                }
                guard let self, let lyrics, !Task.isCancelled, self.saveGeneration == generation else { return }
                let url = try await writer.save(lyrics, for: self.track.url, overwrite: overwrite, automatic: false)
                guard !Task.isCancelled, self.saveGeneration == generation else { return }
                self.savedURL = url
                self.pendingOverwrite = nil
                self.didSave(self.track.url)
            } catch LyricsDownloadError.existingFile {
                guard let self, !Task.isCancelled, self.saveGeneration == generation else { return }
                self.pendingOverwrite = lyrics
                self.needsOverwriteConfirmation = true
            } catch {
                guard let self, !Task.isCancelled, self.saveGeneration == generation else { return }
                self.errorMessage = lyrics == nil ? lyricsDownloadMessage(for: error) :
                    String.localizedStringWithFormat(
                        String(appLocalized: "Could not save the LRC file. Check folder write access: %1$@"), error.localizedDescription
                    )
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        saveTask?.cancel()
        searchGeneration += 1
        saveGeneration += 1
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        isSearching = false
        hasSearched = false
        candidates = []
        selection = nil
        clearSaveState()
    }

    private func clearSaveState() {
        saveTask?.cancel()
        saveGeneration += 1
        pendingOverwrite = nil
        savedURL = nil
        errorMessage = nil
        needsOverwriteConfirmation = false
        isSaving = false
    }
}
