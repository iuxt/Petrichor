#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Capture SQL and bound arguments emitted by the actual production query methods,
# then execute them against an isolated SQLite fixture (no app library access).
sed '/^import GRDB$/d' Managers/Database/DMSearchQueries.swift > "$test_dir/Queries.swift"
python3 - "$test_dir/Setup.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Managers/Database/DMSetup.swift').read_text()
start = source.index('    // MARK: - FTS5 Triggers')
end = source.index('    // MARK: - Create All Indices', start)
Path(sys.argv[1]).write_text('import Foundation\nextension DatabaseManager {\n' + source[start:end] + '}\n')
assert 'try DatabaseManager.rebuildFTSSearchIndex(in: db)' in Path('Managers/Database/DatabaseMigration.swift').read_text()
PY
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
struct Database {
    static var statements: [String] = []
    func execute(sql: String) throws { Self.statements.append(sql) }
}
extension Int {
    static func fetchOne(_ db: Database, sql: String) throws -> Int? { 0 }
}
struct DatabaseQueue {
    func read<T>(_ body: (Database) throws -> T) rethrows -> T { try body(Database()) }
}
final class DatabaseManager { let dbQueue = DatabaseQueue() }
enum Logger {
    static func error(_ message: String) { fatalError(message) }
    static func info(_ message: String) {}
}
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
            "C++", "AC/DC", "say\"hi", "lack", "missing", "   ",
            "know", "KNOW", "kn", "unknown", "composer", "genre", "year",
            "Back know", "Back kn", "know You"
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
        for query in ["know", "kn"] {
            Track.captures = []
            _ = db.searchTracksForPlaylist(query, excludingTrackIds: [14], limit: 2)
            output.append(["query": "playlist:" + query, "captures": Track.captures])
        }
        UserDefaults.standard.setVolatileDomain(["hideDuplicateTracks": true], forName: UserDefaults.argumentDomain)
        for query in ["Back AC", "Back AC/DC"] {
            Track.captures = []
            _ = db.searchTracksUsingFTS(query)
            output.append(["query": "hide:" + query, "captures": Track.captures])
        }
        try DatabaseManager.rebuildFTSSearchIndex(in: Database())
        let data = try JSONSerialization.data(withJSONObject: ["queries": output, "setup": Database.statements])
        print(String(decoding: data, as: UTF8.self))
    }
}
SWIFT
swiftc -parse-as-library "$test_dir/Queries.swift" "$test_dir/Setup.swift" "$test_dir/Harness.swift" -o "$test_dir/queries"
"$test_dir/queries" > "$test_dir/queries.json"
python3 - "$test_dir/queries.json" <<'PY'
import json, sqlite3, sys
production = json.load(open(sys.argv[1]))
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
    values = [title, '', artist, 'Unknown Album', 'Unknown Album Artist', 'Unknown Composer', 'Unknown Genre', 'Unknown Year']
    conn.execute('INSERT INTO tracks VALUES (' + ','.join('?' for _ in range(10)) + ')', [id] + values + [duplicate])
    conn.execute('INSERT INTO tracks_fts VALUES (' + ','.join('?' for _ in range(9)) + ')', [id] + values)
# Genuine metadata containing "know" must remain searchable in every field.
for id, column in enumerate(columns, 14):
    values = [''] * len(columns)
    values[columns.index(column)] = 'Know You' if column == 'title' else 'Unknown Pleasures'
    conn.execute('INSERT INTO tracks VALUES (' + ','.join('?' for _ in range(10)) + ')', [id] + values + [0])
    conn.execute('INSERT INTO tracks_fts VALUES (' + ','.join('?' for _ in range(9)) + ')', [id] + values)
# Isolate every sentinel, including the legacy album-artist spelling.
sentinels = dict(artist='Unknown Artist', album='Unknown Album', album_artist='Unknown Album Artist',
                 composer='Unknown Composer', genre='Unknown Genre', year='Unknown Year')
for id, (column, value) in enumerate(list(sentinels.items()) + [('album_artist', 'Unknown Artist')], 30):
    values = [''] * len(columns)
    values[columns.index(column)] = value
    conn.execute('INSERT INTO tracks VALUES (' + ','.join('?' for _ in range(10)) + ')', [id] + values + [0])
    conn.execute('INSERT INTO tracks_fts VALUES (' + ','.join('?' for _ in range(9)) + ')', [id] + values)
original_tracks = conn.execute('SELECT * FROM tracks').fetchall()
# Reproduce the old populated index, then execute the same repair used by migration.
assert len(conn.execute('SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?', ('"know"',)).fetchall()) > 8
for sql in production['setup']:
    conn.execute(sql)
assert conn.execute('SELECT * FROM tracks').fetchall() == original_tracks
expected = {
    'Back AC': [1,2], 'Back AC/DC': [1,2], 'Back\tAC/DC': [1,2],
    'Back\nAC/DC': [1,2], 'Back　AC/DC': [1,2], '月 周': [3],
    '月光 周杰伦': [3], '月光 周': [3], '月': [3,4], '97': [13],
    '100%': [5], 'a_': [7], 'a\\': [9], 'C++': [10], 'AC/DC': [1,2],
    'say"hi': [11], 'lack': [1,12], 'missing': [], '   ': [],
    'excluded': [2], 'hide:Back AC': [1], 'hide:Back AC/DC': [1],
    'know': list(range(14,22)), 'KNOW': list(range(14,22)), 'kn': list(range(14,22)),
    'unknown': list(range(15,22)), 'composer': [], 'genre': [], 'year': [],
    'Back know': [], 'Back kn': [], 'know You': [14]
}
for case in production['queries']:
    actual = []
    for capture in case['captures']:
        actual += [row[0] for row in conn.execute(capture['sql'], capture['arguments'])]
    if case['query'].startswith('playlist:'):
        assert len(actual) == 2 and 14 not in actual and set(actual) <= set(range(15,22)), (case['query'], actual)
    else:
        assert sorted(actual) == expected[case['query']], (case['query'], actual)

# New inserts, metadata updates, and deletion must keep the sanitized index in sync.
insert_sql = 'INSERT INTO tracks VALUES (' + ','.join('?' for _ in range(10)) + ')'
conn.execute(insert_sql, [40, 'Unrelated', '', 'Unknown Artist', 'Unknown Album', None, 'Unknown Composer', 'Unknown Genre', 'Unknown Year', 0])
def matches(id, query):
    return bool(conn.execute('SELECT rowid FROM tracks_fts WHERE rowid = ? AND tracks_fts MATCH ?', (id, query)).fetchall())
assert not matches(40, '"know"')
conn.execute("UPDATE tracks SET composer = 'Know Composer' WHERE id = 40")
assert matches(40, '"know"')
conn.execute("UPDATE tracks SET composer = 'Unknown Composer', title = 'Know Me' WHERE id = 40")
assert matches(40, '"know"')
assert not matches(40, '"composer"')
conn.execute("UPDATE tracks SET title = 'Unrelated' WHERE id = 40")
assert not matches(40, '"know"')
conn.execute('DELETE FROM tracks WHERE id = 40')
assert not conn.execute('SELECT rowid FROM tracks_fts WHERE rowid = 40').fetchall()
print('Production search SQL passed: placeholder index repair/triggers, genuine metadata, short/mixed tokens, CJK, ranking constraints, literals, exclusions and duplicates')
PY
