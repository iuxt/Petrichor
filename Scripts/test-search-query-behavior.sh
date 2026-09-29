#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Capture SQL and bound arguments emitted by the actual production query methods,
# then execute them against an isolated SQLite fixture (no app library access).
sed '/^import GRDB$/d' Managers/Database/DMSearchQueries.swift > "$test_dir/Queries.swift"
cat > "$test_dir/Harness.swift" <<'SWIFT'
import Foundation
protocol DatabaseValueConvertible {}
extension String: DatabaseValueConvertible {}
extension Int64: DatabaseValueConvertible {}
struct StatementArguments: ExpressibleByArrayLiteral {
    let values: [DatabaseValueConvertible]
    init(_ values: [DatabaseValueConvertible]) { self.values = values }
    init(arrayLiteral elements: DatabaseValueConvertible...) { values = elements }
}
struct Database {}
struct DatabaseQueue {
    func read<T>(_ body: (Database) throws -> T) rethrows -> T { try body(Database()) }
}
final class DatabaseManager { let dbQueue = DatabaseQueue() }
enum Logger { static func error(_ message: String) { fatalError(message) } }
struct Track {
    static var captures: [[String: Any]] = []
    static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments) throws -> [Track] {
        captures.append(["sql": sql, "arguments": arguments.values.map { $0 as Any }])
        return []
    }
}
@main struct Harness {
    static func main() throws {
        let db = DatabaseManager()
        let cases = [
            "Back AC", "Back AC/DC", "Back\tAC/DC", "Back\nAC/DC", "Back　AC/DC",
            "月 周", "月光 周杰伦", "月光 周", "月", "97", "100%", "a_", "a\\",
            "C++", "AC/DC", "say\"hi", "lack", "missing", "   "
        ]
        var output: [[String: Any]] = []
        for query in cases {
            Track.captures = []
            _ = db.searchTracksUsingFTS(query)
            output.append(["query": query, "captures": Track.captures])
        }
        Track.captures = []
        _ = db.searchTracksForPlaylist("Back AC", excludingTrackIds: [1], limit: 1)
        output.append(["query": "excluded", "captures": Track.captures])
        UserDefaults.standard.setVolatileDomain(["hideDuplicateTracks": true], forName: UserDefaults.argumentDomain)
        for query in ["Back AC", "Back AC/DC"] {
            Track.captures = []
            _ = db.searchTracksUsingFTS(query)
            output.append(["query": "hide:" + query, "captures": Track.captures])
        }
        let data = try JSONSerialization.data(withJSONObject: output)
        print(String(decoding: data, as: UTF8.self))
    }
}
SWIFT
swiftc -parse-as-library "$test_dir/Queries.swift" "$test_dir/Harness.swift" -o "$test_dir/queries"
"$test_dir/queries" > "$test_dir/queries.json"
python3 - "$test_dir/queries.json" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(':memory:')
columns = ['title', 'filename_stem', 'artist', 'album', 'album_artist', 'composer', 'genre', 'year']
conn.execute('CREATE TABLE tracks(id INTEGER PRIMARY KEY, ' + ','.join(c + ' TEXT' for c in columns) + ', is_duplicate INTEGER)')
conn.execute("CREATE VIRTUAL TABLE tracks_fts USING fts5(track_id UNINDEXED, " + ','.join(columns) + ", tokenize='trigram')")
fixtures = [
    (1, 'Back in Black', 'AC/DC', 0), (2, 'Back Again', 'AC/DC', 1),
    (3, '月光', '周杰伦', 0), (4, '月亮', '其他', 0),
    (5, '100%', '', 0), (6, '1000', '', 0), (7, 'a_', '', 0),
    (8, 'ab', '', 0), (9, 'a\\', '', 0), (10, 'C++', '', 0),
    (11, 'say"hi', '', 0), (12, 'Blackbird', '', 0), (13, '1997', '', 0)
]
for id, title, artist, duplicate in fixtures:
    values = [title, '', artist, '', '', '', '', '']
    conn.execute('INSERT INTO tracks VALUES (' + ','.join('?' for _ in range(10)) + ')', [id] + values + [duplicate])
    conn.execute('INSERT INTO tracks_fts VALUES (' + ','.join('?' for _ in range(9)) + ')', [id] + values)
expected = {
    'Back AC': [1,2], 'Back AC/DC': [1,2], 'Back\tAC/DC': [1,2],
    'Back\nAC/DC': [1,2], 'Back　AC/DC': [1,2], '月 周': [3],
    '月光 周杰伦': [3], '月光 周': [3], '月': [3,4], '97': [13],
    '100%': [5], 'a_': [7], 'a\\': [9], 'C++': [10], 'AC/DC': [1,2],
    'say"hi': [11], 'lack': [1,12], 'missing': [], '   ': [],
    'excluded': [2], 'hide:Back AC': [1], 'hide:Back AC/DC': [1]
}
for case in json.load(open(sys.argv[1])):
    actual = []
    for capture in case['captures']:
        actual += [row[0] for row in conn.execute(capture['sql'], capture['arguments'])]
    assert sorted(actual) == expected[case['query']], (case['query'], actual)
print('Production search SQL passed: short/mixed tokens, CJK, whitespace, literals, exclusions and duplicates')
PY
