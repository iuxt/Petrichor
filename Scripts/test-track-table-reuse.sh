#!/usr/bin/env bash
# Native-window regression; requires a logged-in macOS GUI session.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/Stubs.swift" <<'SWIFT'
import AppKit
import Foundation

enum About { static let bundleIdentifier = "thumbnail-regression" }
enum Logger {
    static func error(_ message: String) { fatalError(message) }
    static func warning(_ message: String) { print(message) }
}
enum AlbumArtFormat {
    static let maxArtworkSize = 20 * 1024 * 1024
    static let maxArtworkPixelDimension = 8000
    static let supportedExtensions = ["jpg", "png"]
    static let knownFilenames = ["cover"]
    static func isSupported(_ ext: String) -> Bool { supportedExtensions.contains(ext.lowercased()) }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
final class CountingFileManager: FileManager, @unchecked Sendable {
    let listings = Counter()
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        listings.increment()
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
enum MetadataEngine {
    static let rawReads = Counter()
    static let largeReads = Counter()
    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        largeReads.increment()
        return nil
    }
    static func extractRawEmbeddedArtwork(from url: URL) async -> Data? {
        rawReads.increment()
        return nil
    }
}

import SwiftUI
struct CueTrackSegment: Equatable { let sheetURL: URL }
struct Track: Identifiable, Equatable {
    let id: Int
    let url: URL
    var cueSegment: CueTrackSegment?
    var artworkSourceURL: URL { url }
    var libraryPath: String { url.standardizedFileURL.path }
    var trackId: Int64? { Int64(id) }
    var albumId: Int64? { 1 }
    var album: String { "Album" }
    var titleOverride: String? = nil
    var title: String { titleOverride ?? "Track \(id)" }
    var format: String { url.pathExtension }
    var folderId: Int64? = nil
    var lossless: Bool? = nil
    var codec: String? = nil
    var bitrate: Int? = nil
    var sampleRate: Int? = nil
    var channels: Int? = nil
    var albumArtist: String? = nil
    var lastPlayedDate: Date? = nil
    var isDuplicate = false
    var albumArtworkData: Data? = nil
    var artist: String { "Artist" }
    var genre: String { "Genre" }
    var year: String { "2026" }
    var composer: String { "Composer" }
    var filename: String { url.lastPathComponent }
    var duration: Double { 180 }
    var trackNumber: Int? { id }
    var discNumber: Int? { 1 }
    var dateAdded: Date? { nil }
    var playCount: Int { 0 }
    var sortableLastPlayedDate: Date { .distantPast }
    var displayArtist: String { artist }
    var displayAlbum: String { album }
    var displayGenre: String { genre }
    var displayYear: String { year }
    var displayComposer: String { composer }

}
enum TableRowSize: String { case expanded, compact; var displayName: String { rawValue }; var rowHeight: CGFloat { self == .expanded ? 56 : 28 } }
enum ViewDefaults { static let listArtworkSize: CGFloat = 40 }
enum Icons { static let musicNote = "music.note"; static let playFill = "play.fill"; static let pauseFill = "pause.fill" }

extension String { init(appLocalized: String) { self = appLocalized } }
enum HelperUtils { static func formattedDuration(_ value: Double) -> String { "3:00" } }
struct Playlist { let id: UUID }
final class PlaybackManager: ObservableObject {
    var currentTrack: Track?
    var isPlaying = false
    func togglePlayPause() {}
}
final class PlaylistManager: ObservableObject {
    enum QueueSource { case library, folder, playlist }
    var playlists: [Playlist] = []
    var currentPlaylist: Playlist?
    var currentQueueSource: QueueSource = .library
    var isShuffleEnabled = false
    func showCreatePlaylistModal(with tracks: [Track]) {}
    func playTrackByAppendingToQueue(_ track: Track) {}
    func playTrack(_ track: Track, fromTracks: [Track]) {}
}
extension View { func hoverEffect(activeBackgroundColor: Color) -> some View { self } }
extension Notification.Name {
    static let trackTableSortChanged = Notification.Name("trackTableSortChanged")
    static let trackTableRowSizeChanged = Notification.Name("trackTableRowSizeChanged")
    static let trackSelectionChanged = Notification.Name("trackSelectionChanged")
    static let libraryDataDidChange = Notification.Name("libraryDataDidChange")
    static let downloadedArtworkDidChange = Notification.Name("downloadedArtworkDidChange")
    static let playEntityTracks = Notification.Name("playEntityTracks")
    static let playPlaylistTracks = Notification.Name("playPlaylistTracks")
    static let createPlaylistFromSelection = Notification.Name("createPlaylistFromSelection")
}

import SwiftUI

// MARK: - Sort Field Enum


SWIFT
# Match production equality, including metadata-only updates with the same ID.
python3 - "$test_dir/Stubs.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Models/Core/Track.swift').read_text()
method = source[source.index('    static func =='):source.index('    // MARK: - Hashable')]
with open(sys.argv[1], 'a') as output:
    output.write('\nextension Track {\n' + method + '\n}\n')
PYTHON
cat > "$test_dir/UI.swift" <<'SWIFT'
import AppKit
import SwiftUI

@MainActor enum ActionProbe { static var activations = 0 }

struct ScrollTest: View {
    let tracks: [Track]
    @State var selection = Set<Int>()
    @State var sort = [KeyPathComparator(\Track.title)]
    @State var customization = TableColumnCustomization<Track>()
    var body: some View {
        NativeTrackTable(tracks: tracks, selection: $selection, sortOrder: $sort,
            customization: $customization, rowSize: .expanded, currentTrack: nil,
            isPlaying: false, artworkRevision: 0, onPlay: { _ in ActionProbe.activations += 1 }, onDoubleClick: { _ in ActionProbe.activations += 1 },
            menuItems: { _ in [.button(title: "Play", action: {}), .button(title: "Track Info", action: {})] })
    }
}

struct ColumnPreferencesTest: View {
    let tracks: [Track]
    @State var sort = [KeyPathComparator(\Track.title)]
    @State var rowSize: TableRowSize = .compact
    var body: some View {
        VStack {
            TrackTableOptionsDropdown(sortOrder: $sort, tableRowSize: $rowSize)
            TrackTableView(
                tracks: tracks, playlistID: nil, entityID: nil, queueSource: .library,
                onPlayTrack: { _ in }, contextMenuItems: { _, _ in [] },
                sortOrder: $sort, tableRowSize: $rowSize
            )
        }
        .environmentObject(PlaybackManager())
        .environmentObject(PlaylistManager())
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var heartbeat: Timer?
    var lastBeat = Date()
    var delays: [Double] = []
    var measure = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let tracks = (0..<4000).map { Track(id: $0, url: root.appendingPathComponent("\($0).mp3")) }
        window = NSWindow(contentRect: NSRect(x: 150, y: 120, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Petrichor 4000-row scroll check"
        window.contentView = NSHostingView(rootView: ScrollTest(tracks: tracks))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                if self.measure { self.delays.append(now.timeIntervalSince(self.lastBeat)) }
                self.lastBeat = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let table = findTable(window.contentView!) else { fatalError("No native table") }
            precondition(table.numberOfRows == 4000)
            let initialRange = table.rows(in: table.visibleRect)
            let nextRow = NSMaxRange(initialRange) + 5
            let nextRequest = ArtworkRequest.thumbnail(tracks[nextRow].url, albumTitle: tracks[nextRow].album)
            precondition(TrackThumbnailCache.shared.cachedImage(for: nextRequest)?.image != nil,
                         "nearby offscreen rows should already be prefetched")
            measure = true
            for row in stride(from: 0, through: 3999, by: 20) {
                table.scrollRowToVisible(row)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            table.scrollRowToVisible(3999)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            measure = false
            var rowViews = 0
            table.enumerateAvailableRowViews { _, _ in rowViews += 1 }
            print("Native table row views at bottom: \(rowViews)")
            precondition(rowViews < 40, "offscreen row views must be reused")
            // Prepare a repeat pass, then inspect rendered pixels synchronously
            // after cell creation. Awaiting a task here would hide placeholder flashes.
            for track in tracks {
                _ = await TrackThumbnailCache.shared.image(for: .thumbnail(track.url, albumTitle: track.album))
            }
            let titleColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("title"))
            let readsBeforeRepeat = MetadataEngine.rawReads.value
            for row in stride(from: 0, through: 3999, by: 20) {
                table.scrollRowToVisible(row)
                table.layoutSubtreeIfNeeded()
                let cell = table.view(atColumn: titleColumn, row: row, makeIfNecessary: true) as! NativeTrackTitleCell
                cell.layoutSubtreeIfNeeded()
                let artwork = cell.artwork
                let bitmap = artwork.bitmapImageRepForCachingDisplay(in: artwork.bounds)!
                artwork.cacheDisplay(in: artwork.bounds, to: bitmap)
                let color = bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 4)!.usingColorSpace(.deviceRGB)!
                precondition(color.blueComponent - color.redComponent > 0.3,
                             "warm rows must draw their cover on the first frame, without an async placeholder")
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(MetadataEngine.rawReads.value == readsBeforeRepeat, "warm fast scrolling must not reread metadata")
            print("Fast repeat scrolling: 200 first-frame artwork checks passed")
            table.scrollRowToVisible(3999)
            let coordinator = table.delegate as! NativeTrackTable.Coordinator
            // Keep native selection, context selection and SwiftUI bindings in sync.
            table.selectRowIndexes(IndexSet([3998, 3999]), byExtendingSelection: false)
            precondition(coordinator.parent.selection == Set([3998, 3999]))
            let multipleMenu = coordinator.menu(for: 3999)
            precondition(multipleMenu?.items.count == 2 && table.selectedRowIndexes.count == 2)
            _ = coordinator.menu(for: 3997)
            precondition(table.selectedRowIndexes == IndexSet(integer: 3997))
            (table as! MenuTrackTable).activateSelection?()
            precondition(ActionProbe.activations == 1, "keyboard activation must reach playback")
            let artist = table.headerView!.menu!.items.first { ($0.representedObject as? String) == "artist" }!
            coordinator.toggleColumn(artist)
            precondition(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("artist"))!.isHidden)
            coordinator.toggleColumn(artist)
            precondition(!table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("artist"))!.isHidden)
            table.sortDescriptors = [NSSortDescriptor(key: "title", ascending: false)]
            precondition(!TrackSortField.isAscending(from: coordinator.parent.sortOrder))
            // Position columns stay visible/customizable but cannot sort mixed lists.
            let trackColumn = table.tableColumn(withIdentifier: .init("trackNumber"))!
            let discColumn = table.tableColumn(withIdentifier: .init("discNumber"))!
            precondition(trackColumn.sortDescriptorPrototype == nil && discColumn.sortDescriptorPrototype == nil)
            let mixedOrder = coordinator.parent.sortOrder
            table.sortDescriptors = [NSSortDescriptor(key: "trackNumber", ascending: true)]
            precondition(coordinator.parent.sortOrder == mixedOrder, "mixed-list headers must reject position sorting")
            var albumTable = coordinator.parent
            albumTable.sortContext = .album
            coordinator.update(albumTable)
            precondition(trackColumn.sortDescriptorPrototype != nil && discColumn.sortDescriptorPrototype != nil)
            albumTable.sortContext = .library
            coordinator.update(albumTable)
            precondition(trackColumn.sortDescriptorPrototype == nil && discColumn.sortDescriptorPrototype == nil)
            let sorted = delays.sorted()
            print("UI scrolling: samples=\(sorted.count), p95 main-loop interval=\(sorted[sorted.count * 95 / 100] * 1000)ms, max=\(sorted.last! * 1000)ms")
            let point = table.convert(NSPoint(x: 100, y: table.rect(ofRow: 3999).midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let start = Date()
            let menu = table.menu(for: event)
            print("Bottom row menu lookup: \(Date().timeIntervalSince(start) * 1000)ms; items=\(menu?.items.count ?? -1)")
            #if NEW_CACHE
            let stats = await TrackThumbnailCache.shared.statistics
            print("Cache: images=\(stats.cached), active=\(stats.active), pending=\(stats.pending), waiters=\(stats.waiters)")
            #endif
            var editedTracks = coordinator.parent.tracks
            editedTracks[3999].titleOverride = "Edited title"
            let previous = coordinator.parent
            coordinator.update(NativeTrackTable(
                tracks: editedTracks, selection: .constant(previous.selection), sortOrder: .constant(previous.sortOrder),
                customization: .constant(previous.customization), rowSize: previous.rowSize,
                currentTrack: previous.currentTrack, isPlaying: previous.isPlaying, artworkRevision: previous.artworkRevision,
                onPlay: previous.onPlay, onDoubleClick: previous.onDoubleClick, menuItems: previous.menuItems))
            table.layoutSubtreeIfNeeded()
            let editedCell = table.view(atColumn: titleColumn, row: 3999, makeIfNecessary: true) as! NativeTrackTitleCell
            precondition(editedCell.textField?.stringValue == "Edited title",
                         "Native cells must repaint metadata changes even when track IDs and ordering are unchanged")
            print("Native metadata refresh regression passed")
            heartbeat?.invalidate()
            // Use the production toolbar and table together, with an isolated preference domain.
            let suite = "Petrichor-column-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            window.contentView = NSHostingView(rootView: ColumnPreferencesTest(tracks: Array(tracks.prefix(2)))
                .defaultAppStorage(defaults))
            try? await Task.sleep(nanoseconds: 200_000_000)
            let preferencesTable = findTable(window.contentView!)!
            let preferencesCoordinator = preferencesTable.delegate as! NativeTrackTable.Coordinator
            precondition(preferencesTable.tableColumn(withIdentifier: .init("filename"))!.isHidden)
            var columns = NativeTrackTable.columnCustomization(from: Data())
            NativeTrackTable.setColumnVisibility("filename", visible: true, in: &columns)
            NativeTrackTable.setColumnVisibility("artist", visible: false, in: &columns)
            defaults.set(try! JSONEncoder().encode(columns), forKey: NativeTrackTable.columnCustomizationKey)
            try? await Task.sleep(nanoseconds: 200_000_000)
            precondition(!preferencesTable.tableColumn(withIdentifier: .init("filename"))!.isHidden,
                         "shared preferences must update an already mounted table")
            precondition(preferencesTable.tableColumn(withIdentifier: .init("artist"))!.isHidden)
            let filenameItem = preferencesTable.headerView!.menu!.items.first { ($0.representedObject as? String) == "filename" }!
            preferencesCoordinator.toggleColumn(filenameItem)
            try? await Task.sleep(nanoseconds: 200_000_000)
            let saved = NativeTrackTable.columnCustomization(from: defaults.data(forKey: NativeTrackTable.columnCustomizationKey)!)
            precondition(!NativeTrackTable.columns.first { $0.id == "filename" }!.isVisible(in: saved),
                         "header changes must persist to the same preference used by the toolbar")
            // Reopening the table restores the selection.
            window.contentView = NSHostingView(rootView: ColumnPreferencesTest(tracks: Array(tracks.prefix(2)))
                .defaultAppStorage(defaults))
            try? await Task.sleep(nanoseconds: 200_000_000)
            let reopenedTable = findTable(window.contentView!)!
            precondition(reopenedTable.tableColumn(withIdentifier: .init("artist"))!.isHidden)
            defaults.set(Data(), forKey: NativeTrackTable.columnCustomizationKey)
            try? await Task.sleep(nanoseconds: 200_000_000)
            for definition in NativeTrackTable.columns {
                precondition(reopenedTable.tableColumn(withIdentifier: .init(definition.id))!.isHidden == !definition.visible,
                             "restoring defaults must update every column immediately")
            }
            // Prevent an empty table through either column menu.
            var lastColumn = NativeTrackTable.columnCustomization(from: Data())
            for column in NativeTrackTable.columns where column.id != "title" {
                NativeTrackTable.setColumnVisibility(column.id, visible: false, in: &lastColumn)
            }
            NativeTrackTable.setColumnVisibility("title", visible: false, in: &lastColumn)
            precondition(NativeTrackTable.columns.filter { $0.isVisible(in: lastColumn) }.map(\.id) == ["title"])
            let invalid = NativeTrackTable.columnCustomization(from: Data("invalid".utf8))
            precondition(NativeTrackTable.columns.allSatisfy { $0.isVisible(in: invalid) == $0.visible })
            print("Column preferences: live updates, header persistence, reopening, defaults and last-column protection passed")
            NSApp.terminate(nil)
        }
    }
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = findTable(child) { return table } }
        return nil
    }
}
@main struct UI {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--fixture") {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for index in 0..<4000 { try! Data([0]).write(to: root.appendingPathComponent("\(index).mp3")) }
            let context = CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
            try! ImageUtils.encodeJPEG(context.makeImage()!)!.write(to: root.appendingPathComponent("cover.jpg"))
            return
        }
        let app = NSApplication.shared
        let delegate = Delegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

SWIFT
# Redirect the shared disk cache to this disposable test directory.
sed 's/static let shared = ArtworkFileCache()/static let shared = ArtworkFileCache(rootURL: URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent())/' Core/Artwork/ArtworkFileCache.swift > "$test_dir/ArtworkFileCache.swift"
swiftc -O -D NEW_CACHE -parse-as-library "$test_dir/Stubs.swift" "$test_dir/UI.swift" "$test_dir/ArtworkFileCache.swift" \
    Core/Artwork/{ArtworkRequest,ArtworkLoadLimiter,ArtworkResolver,TrackThumbnailCache}.swift \
    Core/Metadata/ExternalArtworkResolver.swift Utilities/ImageUtils.swift Views/Components/Artwork/ThumbnailImageView.swift \
    Views/Components/TrackViews/{NativeTrackTable,TrackTableOptionsDropdown,TrackTableView}.swift \
    Managers/PlaylistSortManager.swift Models/Enums/ContextMenuItem.swift -o "$test_dir/scroll-test"
"$test_dir/scroll-test" "$test_dir/music" --fixture
/usr/bin/time -l "$test_dir/scroll-test" "$test_dir/music"
