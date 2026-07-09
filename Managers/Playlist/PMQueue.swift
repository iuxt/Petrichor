//
// PlaylistManager class extension
//
// This extension contains methods managing playback queue.
//

import Foundation

extension PlaylistManager {
    private func isSameTrack(_ lhs: Track, _ rhs: Track) -> Bool {
        if let lhsId = lhs.trackId, let rhsId = rhs.trackId {
            return lhsId == rhsId
        }

        return lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
    }

    func createLibraryQueue() {
        guard let library = libraryManager else { return }
        currentQueue = library.tracks
        currentPlaylist = nil
        currentQueueSource = .library
        Logger.info("Created playback queue from library")
        if isShuffleEnabled {
            shuffleCurrentQueue()
            Logger.info("Shuffled the playback queue")
        }
    }

    func clearQueue() {
        currentQueue.removeAll()
        currentQueueIndex = -1
        currentPlaylist = nil
        audioPlayer?.stop()
        audioPlayer?.currentTrack = nil
        Logger.info("Cleared playback queue")
    }

    func playNext(_ track: Track) {
        if currentQueue.isEmpty || currentQueueIndex < 0 {
            currentQueue = [track]
            currentQueueIndex = 0
            audioPlayer?.playTrack(track)
            return
        }

        let insertIndex = currentQueueIndex + 1

        if let existingIndex = currentQueue.firstIndex(where: { isSameTrack($0, track) }) {
            currentQueue.remove(at: existingIndex)
            if existingIndex <= currentQueueIndex {
                currentQueueIndex -= 1
            }
        }

        currentQueue.insert(track, at: min(insertIndex, currentQueue.count))
        Logger.info("Added track to playback queue to play up next")
    }

    func addToQueue(_ track: Track) {
        if currentQueue.isEmpty {
            currentQueue = [track]
            currentQueueIndex = 0
            audioPlayer?.playTrack(track)
            return
        }

        if !currentQueue.contains(where: { isSameTrack($0, track) }) {
            currentQueue.append(track)
            Logger.info("Added track to playback queue")
        }
    }

    /// 追加单曲到现有播放队列并立即播放：若曲目已在队列中，则直接跳到它
    /// 播放，不重复添加。保留 `currentPlaylist` / `currentQueueSource`，原队列
    /// 剩余曲目继续按既有顺序播放。用于「搜索结果中点播不打断当前队列」。
    func playTrackByAppendingToQueue(_ track: Track) {
        if let existingIndex = currentQueue.firstIndex(where: { isSameTrack($0, track) }) {
            currentQueueIndex = existingIndex
        } else if currentQueue.isEmpty {
            currentQueue = [track]
            currentQueueIndex = 0
        } else {
            currentQueue.append(track)
            currentQueueIndex = currentQueue.count - 1
        }

        audioPlayer?.playTrack(track)
        audioPlayer?.updateNowPlayingInfo()
        Logger.info("Played track by appending to existing queue: \(track.url)")
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < currentQueue.count else { return }

        if index == currentQueueIndex {
            return
        }

        currentQueue.remove(at: index)
        Logger.info("Remove track from playback queue")

        if index < currentQueueIndex {
            currentQueueIndex -= 1
        }
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < currentQueue.count,
              destinationIndex >= 0, destinationIndex < currentQueue.count,
              sourceIndex != destinationIndex else { return }

        let track = currentQueue.remove(at: sourceIndex)
        currentQueue.insert(track, at: destinationIndex)

        if sourceIndex == currentQueueIndex {
            currentQueueIndex = destinationIndex
        } else if sourceIndex < currentQueueIndex && destinationIndex >= currentQueueIndex {
            currentQueueIndex -= 1
        } else if sourceIndex > currentQueueIndex && destinationIndex <= currentQueueIndex {
            currentQueueIndex += 1
        }
        Logger.info("Moved track in playback queue")
    }

    func playFromQueue(at index: Int) {
        guard index >= 0 && index < currentQueue.count else { return }

        currentQueueIndex = index
        let track = currentQueue[index]
        audioPlayer?.playTrack(track)
    }

    internal func shuffleCurrentQueue() {
        guard !currentQueue.isEmpty else { return }

        if let currentTrack = audioPlayer?.currentTrack,
           let currentIndex = currentQueue.firstIndex(where: { isSameTrack($0, currentTrack) }) {
            var tracksToShuffle = currentQueue
            tracksToShuffle.remove(at: currentIndex)
            tracksToShuffle.shuffle()

            currentQueue = [currentTrack] + tracksToShuffle
            currentQueueIndex = 0
        } else {
            currentQueue.shuffle()
            currentQueueIndex = 0
        }
        Logger.info("Shuffled the playback queue")
    }
}
