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
struct Track: Identifiable, Equatable {
    let id: Int
    let url: URL
    var trackId: Int64? { Int64(id) }
    var albumId: Int64? { 1 }
    var album: String { "Album" }
    var title: String { "Track \(id)" }
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
    var sortableTrackNumber: Int { id }
    var sortableDiscNumber: Int { 1 }
    var sortableDateAdded: Date { .distantPast }
    var displayArtist: String { artist }
    var displayAlbum: String { album }
    var displayGenre: String { genre }
    var displayYear: String { year }
    var displayComposer: String { composer }

}
enum TableRowSize: String { case expanded, compact; var rowHeight: CGFloat { self == .expanded ? 56 : 28 } }
enum ViewDefaults { static let listArtworkSize: CGFloat = 40 }
enum Icons { static let musicNote = "music.note"; static let playFill = "play.fill"; static let pauseFill = "pause.fill" }

extension String { init(appLocalized: String) { self = appLocalized } }
enum HelperUtils { static func formattedDuration(_ value: Double) -> String { "3:00" } }
import SwiftUI

// MARK: - Sort Field Enum


SWIFT
# Use the actual sort mapping, without its unrelated dropdown UI.
sed '/\/\/ MARK: - TrackTableOptionsDropdown/,$d' Views/Components/TrackViews/TrackTableOptionsDropdown.swift >> "$test_dir/Stubs.swift"
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
            heartbeat?.invalidate()
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
    Views/Components/TrackViews/NativeTrackTable.swift Models/Enums/ContextMenuItem.swift -o "$test_dir/scroll-test"
"$test_dir/scroll-test" "$test_dir/music" --fixture
/usr/bin/time -l "$test_dir/scroll-test" "$test_dir/music"
