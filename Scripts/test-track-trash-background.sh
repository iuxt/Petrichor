#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
def method(path,signature):
 s=Path(path).read_text();a=s.index(signature);b=s.index('{',a)+1;depth=1
 while depth:
  if s[b]=='{':depth+=1
  elif s[b]=='}':depth-=1
  b+=1
 return s[a:b].replace('private static','static',1)+'\n'
s='''import Foundation
struct Track:Equatable {var trackId:Int?;var url:URL;var libraryPath:String {url.path}}
struct Folder {var url:URL}
enum AudioFormat {static let supportedExtensions=["flac"]}
enum AlbumArtFormat {static let supportedExtensions=["jpg"];static let knownFilenames=["cover"]}
enum Logger {static func info(_ s:String){};static func error(_ s:String){};static func warning(_ s:String){}}
final class MoveSpy:@unchecked Sendable {
 static let shared=MoveSpy()
 let gate=DispatchSemaphore(value:0)
 private let lock=NSLock()
 private var didStart=false
 private var fail=false
 private var paths:[String]=[]
 var started:Bool {lock.lock();defer{lock.unlock()};return didStart}
 var moved:[String] {lock.lock();defer{lock.unlock()};return paths}
 func reset(failing:Bool) {lock.lock();didStart=false;fail=failing;paths=[];lock.unlock()}
 func move(_ url:URL) throws {
  precondition(!Thread.isMainThread,"File move must run off-main")
  lock.lock();paths.append(url.lastPathComponent);let shouldFail=fail
  if url.pathExtension=="flac" {didStart=true};lock.unlock()
  if url.pathExtension=="flac" {
   precondition(gate.wait(timeout:.now()+5) == .success)
   if shouldFail {throw CocoaError(.fileWriteNoPermission)}
  }
 }
}
@MainActor final class LibraryManager {
 var folders:[Folder]=[];var removals=0
 func removeTrackFromLibrary(_ track:Track) async throws {removals+=1}
}
@MainActor final class Engine {
 func clearNextTrack(){};func stop(){}
}
@MainActor final class PlaybackManager {
 struct TrashMoveSnapshot {
  let track:Track;let fullTrack:Track?;let position:Double;let wasPlaying:Bool
  let restoredPosition:Double;let suspensionGeneration:UInt64
 }
 var playbackRequestGeneration:UInt64=0
 var currentTrack:Track?;var currentFullTrack:Track?
 var currentEntryId:Int?;var currentTime:Double=15;var restoredPosition:Double=0
 var isPlaying=true;var wantsPlaybackActive=true;var resumed=0
 var playlistManager:PlaylistManager!
 var pendingPlaybackRestore:Bool?;var pendingNext:Bool?;var pendingNextWasSkipped=false
 var trackForEntry:[String:Bool]=[:]
 let audioPlayer=Engine()
 func isCurrentTrack(_ t:Track)->Bool {currentTrack?.trackId==t.trackId}
 func isCurrentPlaybackRequest(_ n:UInt64)->Bool {playbackRequestGeneration==n}
 func invalidatePlaybackRequests(){playbackRequestGeneration &+= 1}
 func cancelMetadataRestoreForPlaybackChange(){}
 func stopStateSaveTimer(){}
 func updateNowPlayingInfo(){}
 func resetProgressResolution(engineProgress:Double){}
 func startPlayback(of full:Track,lightweightTrack:Track) {resumed+=1;currentTrack=lightweightTrack;isPlaying=true}
 func playTrack(_ t:Track) {currentTrack=t;currentFullTrack=t;isPlaying=true;playbackRequestGeneration &+= 1}
'''
s+=method('Managers/PlaybackManager.swift','    func prepareCurrentTrackForTrashMove(')
s+=method('Managers/PlaybackManager.swift','    func restoreCurrentTrackAfterFailedTrashMove(')
s+=method('Managers/PlaybackManager.swift','    func handleTrackMovedToTrash(')
s+='''}
enum RepeatMode {case off,one,all}
@MainActor final class PlaylistManager {
 var currentQueue:[Track]=[];var currentQueueIndex=0;var repeatMode:RepeatMode = .off
 weak var audioPlayer:PlaybackManager?
'''
for signature in ['    private func isSameTrack(', '    func removeFromQueue(', '    func removeTrashedTrackFromQueue(']:
 s+=method('Managers/Playlist/PMQueue.swift',signature)
s+=method('Managers/Playlist/PMPlayback.swift','    func playNextAfterRemovingCurrentTrack(')
s+='''}
@MainActor final class AppCoordinator {
 static var shared:AppCoordinator?
 let libraryManager=LibraryManager();let playbackManager=PlaybackManager();let playlistManager=PlaylistManager()
 init() {playbackManager.playlistManager=playlistManager;playlistManager.audioPlayer=playbackManager}
}
enum TrackTrashManager {
'''
s+=method('Core/TrackTrashManager.swift','    private struct TrashMoveResult').replace('private struct','struct',1)
s+='@MainActor\n'+method('Core/TrackTrashManager.swift','    private static func moveTrackCore(')
s+=method('Core/TrackTrashManager.swift','    private struct TrashFileMoveResult').replace('private struct','struct',1)
s+=method('Core/TrackTrashManager.swift','    private static func moveTrackFilesToTrash(')
s+=method('Core/TrackTrashManager.swift','    private static func withLibraryFolderAccess(')
s+='''
 static func libraryFolderAccessURL(containing url:URL,folders:[Folder])->URL? {
  precondition(!Thread.isMainThread,"Bookmark resolution must run off-main")
  return folders.first?.url
 }
 static func moveItemToTrash(_ url:URL,fileManager:FileManager) throws {try MoveSpy.shared.move(url)}
}
'''
Path(sys.argv[1],'Support.swift').write_text(s)
PY
cat > "$test_dir/Main.swift" <<'SWIFT'
import Foundation
@main struct Main {
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let audio=root.appendingPathComponent("Song.flac")
  for name in ["Song.flac","Song.lrc","cover.jpg"] {try Data().write(to:root.appendingPathComponent(name))}
  let track=Track(trackId:1,url:audio)
  let spy=MoveSpy.shared
  for scenario in 0..<3 {
   spy.reset(failing:scenario>0)
   let coordinator=AppCoordinator()
   coordinator.libraryManager.folders=[Folder(url:root)]
   coordinator.playbackManager.currentTrack=track
   coordinator.playbackManager.currentFullTrack=track
   let next=Track(trackId:2,url:root.appendingPathComponent("Other.flac"))
   coordinator.playlistManager.currentQueue=[track,next]
   let work=Task {await TrackTrashManager.moveTrackCore(track,coordinator:coordinator)}
   for _ in 0..<5000 where !spy.started {try await Task.sleep(nanoseconds:1_000_000)}
   precondition(spy.started,"Move worker did not start")
   // The main actor is responsive while the move is still blocked on its worker.
   precondition(coordinator.playlistManager.currentQueue.count==2 && coordinator.libraryManager.removals==0)
   if scenario==2 {
    coordinator.playbackManager.currentTrack=Track(trackId:2,url:root.appendingPathComponent("Other.flac"))
    coordinator.playbackManager.playbackRequestGeneration &+= 1
    coordinator.playbackManager.currentEntryId=9
   }
   spy.gate.signal()
   let result=await work.value
   if scenario==0 {
    precondition(result.audioMoved && result.libraryRemoved && result.failedSidecars.isEmpty)
    precondition(spy.moved.count==3 && coordinator.playbackManager.currentTrack?.trackId==2)
    precondition(coordinator.libraryManager.removals==1 && !coordinator.playlistManager.currentQueue.contains { $0.trackId==1 })
   } else {
    precondition(!result.audioMoved && coordinator.libraryManager.removals==0 && coordinator.playlistManager.currentQueue.count==2)
    precondition(coordinator.playbackManager.resumed==(scenario==1 ? 1:0))
    if scenario==2 {precondition(coordinator.playbackManager.currentTrack?.trackId==2)}
   }
  }
  spy.reset(failing:false)
  let app=AppCoordinator()
  let other=Track(trackId:2,url:root.appendingPathComponent("Other.flac"))
  app.playbackManager.currentTrack=other
  app.playlistManager.currentQueue=[other,track]
  let moving=Task {await TrackTrashManager.moveTrackCore(track,coordinator:app)}
  for _ in 0..<5000 where !spy.started {try await Task.sleep(nanoseconds:1_000_000)}
  precondition(spy.started)
  app.playbackManager.currentTrack=track
  app.playlistManager.currentQueueIndex=1
  spy.gate.signal()
  let moved=await moving.value
  precondition(moved.audioMoved && moved.libraryRemoved)
  precondition(app.playbackManager.currentTrack==nil && app.playlistManager.currentQueue.map(\.trackId)==[2])
  print("Trash: background IO, responsive main actor, success ordering and superseded failure restoration passed")
 }
}
SWIFT
swiftc -parse-as-library "$test_dir/Support.swift" "$test_dir/Main.swift" Core/TrackTrashSidecars.swift -o "$test_dir/test"
"$test_dir/test" "$test_dir"
