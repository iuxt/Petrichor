#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Compile the production scheduling methods with controllable database/sort work.
# Gates force old work to finish last, instead of hoping a timing race occurs.
python3 - "$test_dir/Production.swift" <<'PY'
from pathlib import Path
import sys

def method(file, signature):
    source = Path(file).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

search = method('Managers/Library/LMQueries.swift', '    func updateSearchResults()')
sort = method('Views/Components/TrackViews/TrackTableView.swift', '    private func performBackgroundSort(')
Path(sys.argv[1]).write_text('import Foundation\nextension LibraryManager {\n' + search + '\n}\nextension TableHarness {\n' + sort + '\n}\n')

view = Path('Views/Library/LibraryView.swift').read_text()
sidebar = Path('Views/Library/LibrarySidebarView.swift').read_text()
table = Path('Views/Components/TrackViews/TrackTableView.swift').read_text()
content = Path('Views/Main/ContentView.swift').read_text()
assert '.onChange(of: libraryManager.searchResults)' in view
assert 'guard libraryManager.globalSearchText.isEmpty,' in view
assert 'globalSearchUpdateTask' not in view + sidebar
assert 'Task.sleep' not in sidebar
assert 'if !newTracks.isEmpty' not in table
assert '.onDisappear {\n                sortTask?.cancel()' in table
assert 'oldValue.isEmpty && !newValue.isEmpty' in content
assert 'libraryCachedTracks = libraryManager.searchResults' in content
PY
cat > "$test_dir/Harness.swift" <<'SWIFT'
import Foundation

func expect(_ value: Bool, _ message: String) {
    precondition(value, message)
}

// A synchronous worker that deliberately ignores task cancellation, like SQLite
// or Array.sorted. The caller must still reject its obsolete completion.
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var started: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
struct Track: Sendable {
    let id: Int
    var gate: Gate? = nil
    var title: String { gate?.wait(); return String(id) }
}
enum TimeConstants { static let searchDebounceDuration: UInt64 = 20_000_000 }
enum LibrarySearch {
    static func isSearchableQuery(_ query: String) -> Bool { query.count >= 2 }
}
final class DatabaseManager: @unchecked Sendable {
    struct Reply { let tracks: [Track]; let gate: Gate? }
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var calls: [String] = []
    var queries: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    func prepare(_ query: String, id: Int, gate: Gate? = nil) {
        lock.lock(); defer { lock.unlock() }
        replies[query, default: []].append(Reply(tracks: [Track(id: id)], gate: gate))
    }
    func searchTracksUsingFTS(_ query: String) -> [Track] {
        expect(!Thread.isMainThread, "Database search must not block the main thread")
        lock.lock()
        calls.append(query)
        let reply = replies[query]!.removeFirst()
        lock.unlock()
        reply.gate?.wait()
        return reply.tracks
    }
}
@MainActor final class LibraryManager {
    let databaseManager = DatabaseManager()
    var searchUpdateTask: Task<Void, Never>?
    var globalSearchText = "" { didSet { updateSearchResults() } }
    var searchResults: [Track] = []
    var isSearching = false
}
@MainActor final class TableHarness {
    var tracks: [Track] = []
    var sortedTracks: [Track] = []
    var sortTask: Task<Void, Never>?
    var isCustomSort = false
    var selection: Set<Int> = []
}
@main struct Tests {
    @MainActor static func waitFor(_ gate: Gate) async {
        for _ in 0..<2000 {
            if gate.started { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Worker did not start")
    }
    @MainActor static func main() async {
        let manager = LibraryManager()
        let db = manager.databaseManager
        // Rapid input must run only the final query.
        db.prepare("final", id: 1)
        for query in ["fi", "fin", "fina", "final"] { manager.globalSearchText = query }
        await manager.searchUpdateTask?.value
        expect(db.queries == ["final"], "Intermediate input was not debounced")
        expect(manager.searchResults.map(\.id) == [1] && !manager.isSearching, "Final input was lost")

        // Old searches must never overwrite new results, even A → B → A.
        let oldGate = Gate()
        db.prepare("alpha", id: 2, gate: oldGate)
        manager.globalSearchText = "alpha"
        let oldTask = manager.searchUpdateTask!
        await waitFor(oldGate)
        db.prepare("alpha", id: 3)
        manager.globalSearchText = "beta"
        manager.globalSearchText = "alpha"
        expect(manager.searchResults.isEmpty && manager.isSearching, "Old rows survived query change")
        await manager.searchUpdateTask?.value
        oldGate.release()
        await oldTask.value
        expect(manager.searchResults.map(\.id) == [3], "An obsolete A result replaced a newer A")

        // Same-query refreshes (metadata edits or duplicate settings) invalidate old work.
        let refreshGate = Gate()
        db.prepare("alpha", id: 4, gate: refreshGate)
        manager.updateSearchResults()
        let refreshTask = manager.searchUpdateTask!
        await waitFor(refreshGate)
        db.prepare("alpha", id: 5)
        manager.updateSearchResults()
        await manager.searchUpdateTask?.value
        refreshGate.release()
        await refreshTask.value
        expect(manager.searchResults.map(\.id) == [5], "Stale library refresh won")

        for replacement in ["", "x"] {
            let gate = Gate()
            db.prepare("active", id: 6, gate: gate)
            manager.globalSearchText = "active"
            let task = manager.searchUpdateTask!
            await waitFor(gate)
            manager.globalSearchText = replacement
            gate.release()
            await task.value
            expect(manager.searchResults.isEmpty && !manager.isSearching, "Cleared/short input repopulated")
        }

        let table = TableHarness()
        let order = [KeyPathComparator(\Track.title)]
        // An older, slower sort finishes after the current one.
        let sortGate = Gate()
        table.tracks = [Track(id: 2, gate: sortGate), Track(id: 1, gate: sortGate)]
        table.performBackgroundSort(with: order)
        let oldSort = table.sortTask!
        await waitFor(sortGate)
        table.tracks = [Track(id: 4), Track(id: 3)]
        table.performBackgroundSort(with: order)
        await table.sortTask?.value
        sortGate.release()
        await oldSort.value
        expect(table.sortedTracks.map(\.id) == [3, 4], "Old sort overwrote current results")

        // Empty results and custom playlist order must cancel in-flight sorting.
        for custom in [false, true] {
            let gate = Gate()
            table.tracks = [Track(id: 2, gate: gate), Track(id: 1, gate: gate)]
            table.performBackgroundSort(with: order)
            let task = table.sortTask!
            await waitFor(gate)
            table.tracks = custom ? [Track(id: 9), Track(id: 8)] : []
            table.isCustomSort = custom
            table.selection = [1, 2]
            table.performBackgroundSort(with: order)
            expect(table.selection.isEmpty, "Stale row selection survived")
            gate.release()
            await task.value
            expect(table.sortedTracks.map(\.id) == (custom ? [9, 8] : []), "Stale sort restored old rows")
            table.isCustomSort = false
        }
        print("Search debounce, out-of-order completion, refresh, clear and table sorting tests passed")
    }
}
SWIFT
swiftc -parse-as-library "$test_dir/Production.swift" "$test_dir/Harness.swift" -o "$test_dir/test-search"
"$test_dir/test-search"
