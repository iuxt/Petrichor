import Combine
import Foundation

struct LyricsSearchRequest: Identifiable {
    let id = UUID()
    let track: Track
}

enum LyricsSearchCandidate: Identifiable, Equatable {
    case ttml(AMLLTTMLCandidate)
    case provider(OnlineTagCandidate)

    var id: String {
        switch self {
        case .ttml(let item): "ttml:\(item.id)"
        case .provider(let item): item.id
        }
    }
    var title: String {
        switch self { case .ttml(let item): item.title; case .provider(let item): item.title }
    }
    var artist: String {
        switch self { case .ttml(let item): item.artist; case .provider(let item): item.artist }
    }
    var album: String {
        switch self { case .ttml(let item): item.album; case .provider(let item): item.album }
    }
    var duration: Double? {
        switch self { case .ttml: nil; case .provider(let item): item.duration }
    }
    var isTTML: Bool { if case .ttml = self { true } else { false } }

    var sourceName: String {
        switch self {
        case .ttml: "AMLL"
        case .provider(let item): item.provider.displayName
        }
    }
}

@MainActor
final class LyricsSearchViewModel: ObservableObject {
    let track: Track
    @Published var title: String { didSet { if title != oldValue { resetSearch() } } }
    @Published var artist: String { didSet { if artist != oldValue { resetSearch() } } }
    @Published var source: LyricsSearchSource { didSet { if source != oldValue { resetSearch() } } }
    @Published var includeTranslation: Bool { didSet { if includeTranslation != oldValue { clearSaveState() } } }
    @Published var selection: String? { didSet { if selection != oldValue { clearSaveState() } } }
    @Published private(set) var candidates: [LyricsSearchCandidate] = []
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
        source = settings.source
        includeTranslation = settings.includeTranslation
        self.service = service
        self.writer = writer
        self.didSave = didSave
    }

    var selectedCandidate: LyricsSearchCandidate? { candidates.first { $0.id == selection } }
    var overwriteURL: URL? {
        pendingOverwrite.map { track.url.deletingPathExtension().appendingPathExtension($0.format.rawValue) }
    }
    var canSearch: Bool {
        !isSearching && !isSaving && ![title, artist].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func search() {
        guard canSearch else { return }
        resetSearch()
        isSearching = true
        let generation = searchGeneration
        let service = service, source = source, title = title, artist = artist
        searchTask = Task { [weak self] in
            do {
                let results: [LyricsSearchCandidate]
                if let provider = source.tagProvider {
                    results = try await service.search(provider: provider, title: title, artist: artist)
                        .map(LyricsSearchCandidate.provider)
                } else {
                    results = try await service.searchTTML(title: title, artist: artist)
                        .map(LyricsSearchCandidate.ttml)
                }
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                self.candidates = results
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
                    switch candidate {
                    case .ttml(let item):
                        lyrics = try await service.downloadTTML(item)
                    case .provider(let item):
                        lyrics = try await service.download(item, includeTranslation: includeTranslation)
                    }
                }
                guard let self, let lyrics, !Task.isCancelled, self.saveGeneration == generation else { return }
                let url = try await writer.save(lyrics, for: self.track.url, overwrite: overwrite, automatic: false)
                guard !Task.isCancelled, self.saveGeneration == generation else { return }
                self.savedURL = url
                self.pendingOverwrite = nil
                self.didSave(self.track.url)
                LyricsDownloadNotice.success(url, for: self.track.url)
            } catch LyricsDownloadError.existingFile {
                guard let self, !Task.isCancelled, self.saveGeneration == generation else { return }
                self.pendingOverwrite = lyrics
                self.needsOverwriteConfirmation = true
            } catch {
                guard let self, !Task.isCancelled, self.saveGeneration == generation else { return }
                self.errorMessage = lyrics == nil ? lyricsDownloadMessage(for: error) :
                    String.localizedStringWithFormat(
                        String(appLocalized: "Could not save the lyrics file. Check folder write access: %1$@"), error.localizedDescription
                    )
                LyricsDownloadNotice.failure(for: self.track.url, reason: self.errorMessage ?? "")
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
