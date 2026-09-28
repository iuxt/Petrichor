import Combine
import Foundation

@MainActor
final class OnlineTagLookupViewModel: ObservableObject {
    @Published var title: String { didSet { invalidateSearch() } }
    @Published var artist: String { didSet { invalidateSearch() } }
    @Published var provider: OnlineTagProvider = .netease { didSet { invalidateSearch() } }
    @Published var selection: String?
    @Published private(set) var candidates: [OnlineTagCandidate] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var errorMessage: String?

    private let service: any OnlineTagSearching
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    init(title: String, artist: String, service: any OnlineTagSearching = OnlineTagLookupService()) {
        self.title = title
        self.artist = artist
        self.service = service
    }

    var canSearch: Bool {
        !isSearching && ![title, artist].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var selectedCandidate: OnlineTagCandidate? {
        candidates.first { $0.id == selection }
    }

    func search() {
        guard canSearch else { return }
        invalidateSearch()
        isSearching = true
        let requestGeneration = generation
        let service = service
        let provider = provider
        let title = title
        let artist = artist
        searchTask = Task { [weak self] in
            do {
                let results = try await service.search(provider: provider, title: title, artist: artist)
                guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
                self.candidates = results
                self.isSearching = false
                self.hasSearched = true
                self.searchTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == requestGeneration else { return }
                self.isSearching = false
                self.hasSearched = true
                self.searchTask = nil
                if (error as? URLError)?.code == .timedOut {
                    self.errorMessage = String(appLocalized: "The tag search timed out. Please try again.")
                } else if let error = error as? OnlineTagLookupError, error == .invalidResponse {
                    self.errorMessage = String(appLocalized: "The provider returned an unreadable response. Try another source.")
                } else {
                    self.errorMessage = String(appLocalized: "Could not search for tags. Check your connection or try another source.")
                }
            }
        }
    }

    func invalidateSearch() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        hasSearched = false
        candidates = []
        selection = nil
        errorMessage = nil
    }
}
