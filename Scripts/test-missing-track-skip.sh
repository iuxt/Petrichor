#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
s=Path('Managers/Playlist/PMPlayback.swift').read_text()
a=s.index('    nonisolated static func nextAvailableQueueIndex(')
b=s.index('\n    /// Resolves the index',a)
Path(sys.argv[1],'Support.swift').write_text('''import Foundation
struct Track {let url:URL}
enum RepeatMode {case off,one,all}
@MainActor final class PlaylistManager {
'''+s[a:b]+'}\n')
PY
cat > "$test_dir/Main.swift" <<'SWIFT'
import Foundation
@main struct Main {
 static func main() async {
  let queue=(0..<10000).map {Track(url:URL(fileURLWithPath:"/music/\($0).flac"))}
  await Task.detached {
   for mode in [RepeatMode.off,.one,.all] {
    var calls=0
    let absent=PlaylistManager.nextAvailableQueueIndex(in:queue,after:0,repeatMode:mode) {_ in
     precondition(!Thread.isMainThread)
     calls+=1;return false
    }
    precondition(absent == nil && calls == queue.count-1)
   }
   let exists:(URL)->Bool = {$0.lastPathComponent == "1.flac"}
   precondition(PlaylistManager.nextAvailableQueueIndex(in:queue,after:0,repeatMode:.one,fileExists:exists)==1)
   precondition(PlaylistManager.nextAvailableQueueIndex(in:queue,after:9999,repeatMode:.off,fileExists:exists)==nil)
   precondition(PlaylistManager.nextAvailableQueueIndex(in:queue,after:9999,repeatMode:.all,fileExists:exists)==1)
   precondition(PlaylistManager.nextAvailableQueueIndex(in:[],after:0,repeatMode:.all,fileExists:exists)==nil)
   precondition(PlaylistManager.nextAvailableQueueIndex(in:[queue[0]],after:0,repeatMode:.one,fileExists:exists)==nil)
  }.value
  print("Missing tracks: bounded background search, repeat-one, wraparound and empty queues passed")
 }
}
SWIFT
swiftc -parse-as-library "$test_dir/Support.swift" "$test_dir/Main.swift" -o "$test_dir/test"
"$test_dir/test"
