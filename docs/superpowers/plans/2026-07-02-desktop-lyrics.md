# Desktop Lyrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an always-on-top desktop lyrics window with Settings controls for enablement, click-through lock, font family, font size, and persistent position.

**Architecture:** Add a small pure lyric-line selection helper first, then layer a SwiftUI provider/view and an AppKit window manager on top. The window manager follows the existing mini player pattern for borderless windows, frame persistence, and environment wiring while keeping the main lyrics sidebar unchanged.

**Tech Stack:** Swift, SwiftUI, AppKit `NSWindow`, `UserDefaults/@AppStorage`, existing `LyricsStore`, existing `PlaybackManager`, shell script checks, `xcodebuild`.

---

## File Structure

- Create `Core/DesktopLyricsLineSelection.swift`: pure helper for deriving current and next desktop lyric lines from `[LyricLine]`.
- Create `Scripts/test-desktop-lyrics-line-selection.sh`: scriptable tests for the pure helper without launching the app.
- Create `Views/DesktopLyrics/DesktopLyricsLineProvider.swift`: observable model that loads lyrics through `LyricsStore`, observes playback state, and exposes desktop display states.
- Create `Views/DesktopLyrics/DesktopLyricsView.swift`: compact two-line SwiftUI desktop lyrics surface with drag behavior.
- Create `Views/DesktopLyrics/DesktopLyricsWindowManager.swift`: AppKit owner for the floating borderless window, click-through behavior, and frame persistence.
- Modify `Application/AppDelegate.swift`: register default desktop lyrics settings.
- Modify `PetrichorApp.swift`: open/close/update the desktop lyrics window from app-level settings changes.
- Modify `Views/Settings/AppearanceTabView.swift`: add a `Desktop Lyrics` section.
- Modify `Utilities/DiagnosticSnapshot.swift`: include desktop lyrics settings in diagnostics.
- Modify `Resources/Localizable.xcstrings`: add localized entries for new user-facing strings after Swift string extraction.

No Xcode project file changes are expected because the project uses filesystem-synchronized root groups for `Core`, `Views`, `Application`, `Managers`, `Utilities`, and `Resources`.

---

### Task 1: Pure Desktop Lyric Line Selection

**Files:**
- Create: `Core/DesktopLyricsLineSelection.swift`
- Create: `Scripts/test-desktop-lyrics-line-selection.sh`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Write the failing script test**

Create `Scripts/test-desktop-lyrics-line-selection.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual: \(actual)\n", stderr)
        exit(1)
    }
}

func assertNil<T>(_ actual: T?, _ message: String) {
    if actual != nil {
        fputs("FAIL: \(message)\nexpected nil, actual: \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

let timed = [
    LyricLine(text: "first", startTime: 0, endTime: 10),
    LyricLine(text: "", startTime: 10, endTime: 12),
    LyricLine(text: "second", startTime: 12, endTime: 20),
    LyricLine(text: "third", startTime: 20, endTime: nil)
]

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 4),
    DesktopLyricsDisplayLines(current: "first", next: "second"),
    "synced lyrics select current line and next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 11),
    DesktopLyricsDisplayLines(current: "second", next: "third"),
    "empty active lines advance to the next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: -1),
    DesktopLyricsDisplayLines(current: "first", next: "second"),
    "times before the first timestamp show the first two non-empty lines"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 22),
    DesktopLyricsDisplayLines(current: "third", next: nil),
    "last synced line has no next line"
)

let plain = [
    LyricLine(text: "", startTime: 0),
    LyricLine(text: "plain one", startTime: 0),
    LyricLine(text: "plain two", startTime: 0)
]

assertEqual(
    DesktopLyricsLineSelection.plainDisplayLines(lines: plain),
    DesktopLyricsDisplayLines(current: "plain one", next: "plain two"),
    "plain lyrics use first two non-empty lines"
)

assertNil(
    DesktopLyricsLineSelection.plainDisplayLines(lines: [LyricLine(text: "   ", startTime: 0)]),
    "blank lyrics do not produce display lines"
)

print("Desktop lyrics line selection tests passed")
SWIFT

swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/DesktopLyricsLineSelection.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/DesktopLyricsLineSelectionTests"

"$TMP_DIR/DesktopLyricsLineSelectionTests"
```

- [ ] **Step 2: Run the script and verify it fails**

Run:

```bash
chmod +x Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected: FAIL because `Core/DesktopLyricsLineSelection.swift` does not exist.

- [ ] **Step 3: Add the pure line selection helper**

Create `Core/DesktopLyricsLineSelection.swift`:

```swift
import Foundation

struct DesktopLyricsDisplayLines: Equatable {
    let current: String
    let next: String?
}

enum DesktopLyricsLineSelection {
    static func syncedDisplayLines(lines: [LyricLine], at time: TimeInterval) -> DesktopLyricsDisplayLines? {
        guard !lines.isEmpty else { return nil }

        let activeIndex = lines.lastIndex { line in
            if let endTime = line.endTime {
                return time >= line.startTime && time < endTime
            }
            return time >= line.startTime
        }

        let currentIndex: Int?
        if let activeIndex {
            currentIndex = nonEmptyIndex(in: lines, from: activeIndex) ?? nonEmptyIndex(in: lines, from: 0)
        } else {
            currentIndex = nonEmptyIndex(in: lines, from: 0)
        }

        guard let currentIndex else { return nil }
        let nextIndex = nonEmptyIndex(in: lines, from: currentIndex + 1)

        return DesktopLyricsDisplayLines(
            current: trimmedText(lines[currentIndex]),
            next: nextIndex.map { trimmedText(lines[$0]) }
        )
    }

    static func plainDisplayLines(lines: [LyricLine]) -> DesktopLyricsDisplayLines? {
        guard let currentIndex = nonEmptyIndex(in: lines, from: 0) else { return nil }
        let nextIndex = nonEmptyIndex(in: lines, from: currentIndex + 1)

        return DesktopLyricsDisplayLines(
            current: trimmedText(lines[currentIndex]),
            next: nextIndex.map { trimmedText(lines[$0]) }
        )
    }

    private static func nonEmptyIndex(in lines: [LyricLine], from startIndex: Int) -> Int? {
        guard startIndex < lines.count else { return nil }
        let boundedStart = max(0, startIndex)
        for index in boundedStart..<lines.count where !trimmedText(lines[index]).isEmpty {
            return index
        }
        return nil
    }

    private static func trimmedText(_ line: LyricLine) -> String {
        line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the script and verify it passes**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected: PASS with `Desktop lyrics line selection tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Core/DesktopLyricsLineSelection.swift Scripts/test-desktop-lyrics-line-selection.sh
git commit -m "test: add desktop lyrics line selection"
```

---

### Task 2: Desktop Lyrics Provider

**Files:**
- Create: `Views/DesktopLyrics/DesktopLyricsLineProvider.swift`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Create the provider**

Create `Views/DesktopLyrics/DesktopLyricsLineProvider.swift`:

```swift
import Combine
import Foundation

@MainActor
final class DesktopLyricsLineProvider: ObservableObject {
    enum DisplayState: Equatable {
        case idle
        case loading
        case lyrics(DesktopLyricsDisplayLines)
        case empty
        case failed
    }

    @Published private(set) var state: DisplayState = .idle

    private weak var playbackManager: PlaybackManager?
    private weak var libraryManager: LibraryManager?
    private var loadTask: Task<Void, Never>?
    private var loadedTrackId: UUID?
    private var lyricLines: [LyricLine] = []
    private var hasTimedLyrics = false
    private var isSampling = false

    init(playbackManager: PlaybackManager, libraryManager: LibraryManager) {
        self.playbackManager = playbackManager
        self.libraryManager = libraryManager
    }

    deinit {
        loadTask?.cancel()
        if isSampling {
            playbackManager?.setFineProgressSampling(false)
        }
    }

    func appear() {
        setFineProgressSampling(true)
        loadLyricsForCurrentTrack(forceReload: false)
    }

    func disappear() {
        loadTask?.cancel()
        setFineProgressSampling(false)
    }

    func currentTrackChanged() {
        loadedTrackId = nil
        lyricLines = []
        hasTimedLyrics = false
        loadLyricsForCurrentTrack(forceReload: false)
    }

    func playbackTimeChanged(_ time: TimeInterval) {
        guard hasTimedLyrics else { return }
        updateTimedDisplay(at: time)
    }

    private func loadLyricsForCurrentTrack(forceReload: Bool) {
        guard let playbackManager, let libraryManager else {
            state = .failed
            return
        }

        guard let track = playbackManager.currentTrack else {
            loadTask?.cancel()
            loadedTrackId = nil
            lyricLines = []
            hasTimedLyrics = false
            state = .idle
            return
        }

        if !forceReload, loadedTrackId == track.id, !lyricLines.isEmpty {
            publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            return
        }

        loadedTrackId = track.id

        if !forceReload, let cached = LyricsStore.shared.cachedLyrics(for: track.id) {
            lyricLines = cached.lines
            hasTimedLyrics = cached.hasTimed
            publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            return
        }

        loadTask?.cancel()
        state = .loading
        lyricLines = []
        hasTimedLyrics = false

        loadTask = Task { [weak self, weak libraryManager, weak playbackManager] in
            guard let self, let libraryManager, let playbackManager else { return }
            do {
                let result = try await LyricsStore.shared.lyrics(
                    for: track,
                    using: libraryManager.databaseManager.dbQueue,
                    databaseManager: libraryManager.databaseManager
                )

                guard !Task.isCancelled else { return }
                guard playbackManager.currentTrack?.id == track.id else { return }

                self.lyricLines = result.lines
                self.hasTimedLyrics = result.hasTimed
                self.publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            } catch {
                guard !Task.isCancelled else { return }
                guard playbackManager.currentTrack?.id == track.id else { return }
                self.lyricLines = []
                self.hasTimedLyrics = false
                self.state = .failed
            }
        }
    }

    private func publishLoadedLines(for time: TimeInterval) {
        if hasTimedLyrics {
            updateTimedDisplay(at: time)
        } else if let lines = DesktopLyricsLineSelection.plainDisplayLines(lines: lyricLines) {
            state = .lyrics(lines)
        } else {
            state = .empty
        }
    }

    private func updateTimedDisplay(at time: TimeInterval) {
        if let lines = DesktopLyricsLineSelection.syncedDisplayLines(lines: lyricLines, at: time) {
            state = .lyrics(lines)
        } else {
            state = .empty
        }
    }

    private func setFineProgressSampling(_ enabled: Bool) {
        guard enabled != isSampling else { return }
        playbackManager?.setFineProgressSampling(enabled)
        isSampling = enabled
    }
}
```

- [ ] **Step 2: Run the pure script**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected: PASS with `Desktop lyrics line selection tests passed`.

- [ ] **Step 3: Build to catch provider integration errors**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Views/DesktopLyrics/DesktopLyricsLineProvider.swift
git commit -m "feat: add desktop lyrics provider"
```

---

### Task 3: Desktop Lyrics View

**Files:**
- Create: `Views/DesktopLyrics/DesktopLyricsView.swift`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Create the SwiftUI view**

Create `Views/DesktopLyrics/DesktopLyricsView.swift`:

```swift
import SwiftUI
import AppKit

struct DesktopLyricsView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState

    @StateObject private var provider: DesktopLyricsLineProvider

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false

    @AppStorage("desktopLyricsFontName")
    private var desktopLyricsFontName = DesktopLyricsSettings.systemFontName

    @AppStorage("desktopLyricsFontSize")
    private var desktopLyricsFontSize = 28.0

    @State private var window: NSWindow?
    @State private var dragStartOrigin: CGPoint?
    @State private var dragStartMouse: CGPoint?

    init(provider: DesktopLyricsLineProvider) {
        _provider = StateObject(wrappedValue: provider)
    }

    var body: some View {
        content
            .frame(width: 560, height: 96)
            .background(background)
            .contentShape(Rectangle())
            .gesture(windowMoveGesture)
            .captureDesktopLyricsWindow { capturedWindow in
                window = capturedWindow
                DesktopLyricsWindowManager.shared.applyCurrentSettings()
            }
            .onAppear {
                provider.appear()
            }
            .onDisappear {
                provider.disappear()
            }
            .onChange(of: desktopLyricsClickThrough) {
                DesktopLyricsWindowManager.shared.applyCurrentSettings()
            }
            .onChange(of: playbackManager.currentTrack?.id) {
                provider.currentTrackChanged()
            }
            .onReceive(playbackProgressState.$currentTime) { currentTime in
                provider.playbackTimeChanged(currentTime)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch provider.state {
        case .idle:
            statusText("Not Playing")
        case .loading:
            statusText("Loading lyrics")
        case .empty:
            statusText("No Lyrics Available")
        case .failed:
            statusText("Lyrics Failed to Load")
        case .lyrics(let lines):
            VStack(spacing: 8) {
                Text(lines.current)
                    .font(currentLineFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)

                Text(lines.next ?? " ")
                    .font(nextLineFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
    }

    private func statusText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(currentLineFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.10))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
    }

    private var currentLineFont: Font {
        desktopFont(size: desktopLyricsFontSize, weight: .semibold)
    }

    private var nextLineFont: Font {
        desktopFont(size: desktopLyricsFontSize * 0.85, weight: .regular)
    }

    private func desktopFont(size: CGFloat, weight: Font.Weight) -> Font {
        if desktopLyricsFontName == DesktopLyricsSettings.systemFontName {
            return .system(size: size, weight: weight)
        }
        return .custom(desktopLyricsFontName, size: size).weight(weight)
    }

    private var windowMoveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                guard let window else { return }
                if dragStartOrigin == nil {
                    dragStartOrigin = window.frame.origin
                    dragStartMouse = NSEvent.mouseLocation
                }
                guard let startOrigin = dragStartOrigin, let startMouse = dragStartMouse else { return }
                let current = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + (current.x - startMouse.x),
                    y: startOrigin.y + (current.y - startMouse.y)
                ))
            }
            .onEnded { _ in
                dragStartOrigin = nil
                dragStartMouse = nil
                DesktopLyricsWindowManager.shared.saveFrame()
            }
    }
}

enum DesktopLyricsSettings {
    static let systemFontName = "System"
}

extension View {
    func captureDesktopLyricsWindow(_ onWindow: @escaping (NSWindow) -> Void) -> some View {
        background(DesktopLyricsWindowAccessor(onWindow: onWindow))
    }
}

private struct DesktopLyricsWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

- [ ] **Step 2: Run tests and build**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: script passes. Build fails only with `cannot find 'DesktopLyricsWindowManager' in scope`; Task 4 adds that type before this task is committed.

- [ ] **Step 3: Commit after Task 4 build passes**

```bash
git add Views/DesktopLyrics/DesktopLyricsView.swift
git commit -m "feat: add desktop lyrics view"
```

---

### Task 4: Desktop Lyrics Window Manager

**Files:**
- Create: `Views/DesktopLyrics/DesktopLyricsWindowManager.swift`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Create the AppKit window manager**

Create `Views/DesktopLyrics/DesktopLyricsWindowManager.swift`:

```swift
import SwiftUI
import AppKit

@MainActor
final class DesktopLyricsWindowManager: NSObject {
    static let shared = DesktopLyricsWindowManager()

    private static let frameKey = "PetrichorDesktopLyricsWindowFrame"
    private let defaultSize = NSSize(width: 560, height: 96)

    private var window: DesktopLyricsWindow?

    override private init() {}

    func show() {
        if let window {
            window.orderFrontRegardless()
            applyCurrentSettings()
            return
        }

        guard let coordinator = AppCoordinator.shared else {
            Logger.warning("Cannot open desktop lyrics: AppCoordinator unavailable")
            return
        }

        let provider = DesktopLyricsLineProvider(
            playbackManager: coordinator.playbackManager,
            libraryManager: coordinator.libraryManager
        )

        let root = DesktopLyricsView(provider: provider)
            .environmentObject(coordinator.playbackManager)
            .environmentObject(coordinator.playbackManager.playbackProgressState)

        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let window = DesktopLyricsWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.delegate = self

        restoreFrame(into: window)
        self.window = window
        applyCurrentSettings()
        window.orderFrontRegardless()
    }

    func close() {
        guard let window else { return }
        saveFrame()
        window.close()
    }

    func applyCurrentSettings() {
        guard let window else { return }
        window.ignoresMouseEvents = UserDefaults.standard.bool(forKey: "desktopLyricsClickThrough")
        window.level = .floating
    }

    func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    private func restoreFrame(into window: NSWindow) {
        guard let saved = UserDefaults.standard.string(forKey: Self.frameKey) else {
            window.center()
            return
        }

        let frame = NSRectFromString(saved)
        guard frame.width > 0,
              frame.height > 0,
              NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else {
            window.center()
            return
        }

        window.setFrame(frame, display: false)
    }
}

extension DesktopLyricsWindowManager: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.contentView = nil
        window = nil
    }
}

final class DesktopLyricsWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Run tests and build**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: script passes and build succeeds.

- [ ] **Step 3: Commit the view and manager together if Task 3 was waiting**

```bash
git add Views/DesktopLyrics/DesktopLyricsView.swift Views/DesktopLyrics/DesktopLyricsWindowManager.swift
git commit -m "feat: add desktop lyrics window"
```

---

### Task 5: Settings Defaults and App Startup Wiring

**Files:**
- Modify: `Application/AppDelegate.swift`
- Modify: `PetrichorApp.swift`
- Modify: `Utilities/DiagnosticSnapshot.swift`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Add default settings**

In `Application/AppDelegate.swift`, update `registerUserDefaultsDefaults()` by adding these keys before `MediaBackend.userDefaultsKey`:

```swift
            "desktopLyricsEnabled": false,
            "desktopLyricsClickThrough": false,
            "desktopLyricsFontName": DesktopLyricsSettings.systemFontName,
            "desktopLyricsFontSize": 28.0,
```

The defaults dictionary tail should become:

```swift
            "playerBarBackgroundStyle": "Full width",
            "discoverUpdateInterval": "weekly",
            "discoverTrackCount": 50,
            "desktopLyricsEnabled": false,
            "desktopLyricsClickThrough": false,
            "desktopLyricsFontName": DesktopLyricsSettings.systemFontName,
            "desktopLyricsFontSize": 28.0,
            MediaBackend.userDefaultsKey: true
```

- [ ] **Step 2: Add app-level setting observation**

In `PetrichorApp.swift`, add the setting near the existing `@AppStorage` properties:

```swift
    @AppStorage("desktopLyricsEnabled")
    private var desktopLyricsEnabled = false

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false
```

In the `WindowGroup` content chain, after the existing `.onReceive` modifiers, add:

```swift
                .onAppear {
                    if desktopLyricsEnabled {
                        DesktopLyricsWindowManager.shared.show()
                    }
                }
                .onChange(of: desktopLyricsEnabled) { _, enabled in
                    if enabled {
                        DesktopLyricsWindowManager.shared.show()
                    } else {
                        DesktopLyricsWindowManager.shared.close()
                    }
                }
                .onChange(of: desktopLyricsClickThrough) {
                    DesktopLyricsWindowManager.shared.applyCurrentSettings()
                }
```

- [ ] **Step 3: Add diagnostic snapshot keys**

In `Utilities/DiagnosticSnapshot.swift`, add desktop lyrics settings to the `payload["settings"]` dictionary:

```swift
                "desktopLyricsEnabled": defaults.bool(forKey: "desktopLyricsEnabled"),
                "desktopLyricsClickThrough": defaults.bool(forKey: "desktopLyricsClickThrough"),
                "desktopLyricsFontName": defaults.stringOrNull("desktopLyricsFontName"),
                "desktopLyricsFontSize": defaults.double(forKey: "desktopLyricsFontSize"),
```

- [ ] **Step 4: Run tests and build**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: script passes and build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Application/AppDelegate.swift PetrichorApp.swift Utilities/DiagnosticSnapshot.swift
git commit -m "feat: wire desktop lyrics settings"
```

---

### Task 6: Appearance Settings UI

**Files:**
- Modify: `Views/Settings/AppearanceTabView.swift`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Add AppStorage properties and font families**

In `Views/Settings/AppearanceTabView.swift`, add these properties after `miniPlayerAlwaysOnTop`:

```swift
    @AppStorage("desktopLyricsEnabled")
    private var desktopLyricsEnabled = false

    @AppStorage("desktopLyricsClickThrough")
    private var desktopLyricsClickThrough = false

    @AppStorage("desktopLyricsFontName")
    private var desktopLyricsFontName = DesktopLyricsSettings.systemFontName

    @AppStorage("desktopLyricsFontSize")
    private var desktopLyricsFontSize = 28.0

    private var desktopLyricsFontFamilies: [String] {
        [DesktopLyricsSettings.systemFontName] + NSFontManager.shared.availableFontFamilies.sorted()
    }
```

- [ ] **Step 2: Add the Desktop Lyrics section**

In `AppearanceTabView.body`, after the `Visibility` section and before the `Customization` section, add:

```swift
            Section("Desktop Lyrics") {
                Toggle("Show desktop lyrics", isOn: $desktopLyricsEnabled)
                    .help("Displays synced lyrics in a floating desktop window")

                Toggle("Lock desktop lyrics", isOn: $desktopLyricsClickThrough)
                    .help("Lets mouse clicks pass through desktop lyrics")
                    .disabled(!desktopLyricsEnabled)

                Picker("Font", selection: $desktopLyricsFontName) {
                    ForEach(desktopLyricsFontFamilies, id: \.self) { fontName in
                        Text(fontName == DesktopLyricsSettings.systemFontName ? String(localized: "System Font") : fontName)
                            .tag(fontName)
                    }
                }
                .disabled(!desktopLyricsEnabled)

                HStack {
                    Slider(value: $desktopLyricsFontSize, in: 18...48, step: 1) {
                        Text("Size")
                    }
                    Text("\(Int(desktopLyricsFontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .disabled(!desktopLyricsEnabled)
            }
```

- [ ] **Step 3: Apply window manager side effects from Settings**

Add these modifiers to the `Form` chain before `.formStyle(.grouped)`:

```swift
        .onChange(of: desktopLyricsEnabled) { _, enabled in
            if enabled {
                DesktopLyricsWindowManager.shared.show()
            } else {
                DesktopLyricsWindowManager.shared.close()
            }
        }
        .onChange(of: desktopLyricsClickThrough) {
            DesktopLyricsWindowManager.shared.applyCurrentSettings()
        }
```

- [ ] **Step 4: Run tests and build**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: script passes and build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Views/Settings/AppearanceTabView.swift
git commit -m "feat: add desktop lyrics settings UI"
```

---

### Task 7: Localization

**Files:**
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Build once to extract new strings**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: build succeeds and string extraction updates or preserves `Resources/Localizable.xcstrings`.

- [ ] **Step 2: Ensure these English keys exist**

Run:

```bash
rg -n '"Desktop Lyrics"|"Show desktop lyrics"|"Lock desktop lyrics"|"Displays synced lyrics in a floating desktop window"|"Lets mouse clicks pass through desktop lyrics"|"Font"|"Size"|"System Font"|"Not Playing"|"No Lyrics Available"|"Lyrics Failed to Load"' Resources/Localizable.xcstrings
```

Expected: every key is present. If `Font` or `Size` already existed, reuse the existing key.

- [ ] **Step 3: Add Simplified Chinese values**

For the new keys in `Resources/Localizable.xcstrings`, set Simplified Chinese values to:

```text
Desktop Lyrics = 桌面歌词
Show desktop lyrics = 显示桌面歌词
Lock desktop lyrics = 锁定桌面歌词
Displays synced lyrics in a floating desktop window = 在桌面浮动窗口中显示同步歌词
Lets mouse clicks pass through desktop lyrics = 允许鼠标点击穿透桌面歌词
System Font = 系统字体
Not Playing = 未播放
Lyrics Failed to Load = 歌词加载失败
```

Reuse existing translations for:

```text
Font = 字体
Size = 大小
No Lyrics Available = 没有可用歌词
Loading lyrics = 正在加载歌词
```

- [ ] **Step 4: Verify key presence**

Run:

```bash
rg -n '"桌面歌词"|"显示桌面歌词"|"锁定桌面歌词"|"在桌面浮动窗口中显示同步歌词"|"允许鼠标点击穿透桌面歌词"|"系统字体"|"未播放"|"歌词加载失败"' Resources/Localizable.xcstrings
```

Expected: every Simplified Chinese value appears at least once.

- [ ] **Step 5: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "l10n: add desktop lyrics strings"
```

---

### Task 8: Final Verification

**Files:**
- Verify all changed files
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Run script test**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected: PASS with `Desktop lyrics line selection tests passed`.

- [ ] **Step 2: Run full app build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 3: Run manual desktop lyrics verification**

Launch the app, open Settings, and verify:

```text
1. Appearance > Desktop Lyrics > Show desktop lyrics opens the floating lyrics window.
2. Turning Show desktop lyrics off closes the floating lyrics window.
3. With Lock desktop lyrics off, dragging the lyrics surface moves the window.
4. After relaunch, the desktop lyrics window restores to the moved position.
5. With Lock desktop lyrics on, mouse clicks pass through to the app underneath.
6. Changing Font updates the visible desktop lyrics font.
7. Changing Size updates the visible desktop lyrics size.
8. Main lyrics sidebar still opens and scrolls as before.
9. Mini player lyrics panel still opens and scrolls as before.
```

- [ ] **Step 4: Inspect git status and recent commits**

Run:

```bash
git status --short
git log --oneline -n 8
```

Expected: only intentional files are modified or the tree is clean after the last commit. Recent commits include the task commits from this plan.

- [ ] **Step 5: Final commit for verification fixes**

If Task 8 required small fixes, commit them:

```bash
git add Core/DesktopLyricsLineSelection.swift Scripts/test-desktop-lyrics-line-selection.sh Views/DesktopLyrics/DesktopLyricsLineProvider.swift Views/DesktopLyrics/DesktopLyricsView.swift Views/DesktopLyrics/DesktopLyricsWindowManager.swift Application/AppDelegate.swift PetrichorApp.swift Views/Settings/AppearanceTabView.swift Utilities/DiagnosticSnapshot.swift Resources/Localizable.xcstrings
git commit -m "fix: polish desktop lyrics integration"
```

If Task 8 required no fixes, do not create an empty commit.
