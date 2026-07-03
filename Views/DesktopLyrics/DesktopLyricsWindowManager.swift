import AppKit
import SwiftUI

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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
