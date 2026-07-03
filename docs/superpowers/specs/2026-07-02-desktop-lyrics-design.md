# Desktop Lyrics Design

## Goal

Add a desktop lyrics feature for Petrichor on macOS. Users can enable it from Settings, choose the lyrics font family and size, lock it into click-through mode, and move it to a position that persists across app launches.

## Scope

The first version adds a compact always-on-top desktop lyrics window that shows the current lyric line and the next lyric line. It integrates with the existing playback and lyrics loading system without changing the main lyrics sidebar, mini player lyrics panel, or immersive lyrics behavior.

The feature includes:

- a Settings toggle to show or hide desktop lyrics
- a Settings toggle to lock the desktop lyrics window and make it ignore mouse events
- a font family picker backed by installed system font families
- a font size control
- persistent desktop lyrics window position

The first version does not include lyric color settings, background style settings, keyboard shortcuts, menu items, snapping, or multi-line scrolling lyrics.

## User Experience

Desktop lyrics appear as a transparent, borderless, floating window above other apps. The window displays two centered lines:

- the current synced lyric line, emphasized with the configured font and size
- the next lyric line, rendered with the same font at lower visual emphasis

When unlocked, users can drag the lyrics area to reposition it. The app saves the window frame after movement. When locked, the window ignores mouse events so clicks and drags pass through to apps underneath. Users must disable lock mode in Settings before moving the window again.

The default window size is 560 by 96 points. The design remains compact, readable on light and dark desktops, and contains no controls inside the desktop window itself.

## Settings

Add a `Desktop Lyrics` section to the `AppearanceTabView` settings page. The section contains:

- `Show desktop lyrics`: bound to `desktopLyricsEnabled`
- `Lock desktop lyrics`: bound to `desktopLyricsClickThrough`
- `Font`: bound to `desktopLyricsFontName`
- `Size`: bound to `desktopLyricsFontSize`

Defaults:

- `desktopLyricsEnabled`: `false`
- `desktopLyricsClickThrough`: `false`
- `desktopLyricsFontName`: system font
- `desktopLyricsFontSize`: `28`

The font size range is `18...48`. Settings changes apply immediately while the desktop lyrics window is open.

## Architecture

Use an AppKit-managed floating window rather than a SwiftUI `WindowGroup`. This follows the mini player's existing pattern for custom borderless windows and gives direct control over transparency, window level, mouse event passthrough, dragging, and frame persistence.

Add these main units:

- `DesktopLyricsWindowManager`: owns the `NSWindow`, creates and closes it, restores and saves its frame, applies always-on-top and click-through behavior, and injects app environment objects into the SwiftUI root view.
- `DesktopLyricsView`: renders the compact two-line lyrics UI and supplies the draggable unlocked surface.
- `DesktopLyricsLineProvider`: loads lyrics through `LyricsStore`, observes playback track and progress changes, and derives the current and next display lines.

`DesktopLyricsWindowManager` uses `AppCoordinator.shared` to access `PlaybackManager`, `PlaybackProgressState`, and `LibraryManager`, matching the dependency injection style used by the mini player window manager.

## Window Behavior

The desktop lyrics window is:

- borderless
- transparent with text shadow and, if needed for contrast, a low-opacity material background
- non-opaque
- excluded from the normal windows menu
- above normal app windows
- not a key user workflow surface

When `desktopLyricsClickThrough` is enabled, the manager sets the window to ignore mouse events. When disabled, the SwiftUI view provides a drag surface that lets users move the window. Moving the window saves its global frame.

The manager persists the frame under `PetrichorDesktopLyricsWindowFrame`. On restore, a saved frame is used only if it intersects a currently connected screen. Otherwise, the window is centered.

## Lyrics Data Flow

`DesktopLyricsLineProvider` responds to the current track and playback progress:

1. When there is no current track, expose an idle state such as `Not Playing`.
2. When the track changes, clear the displayed lines and load lyrics through `LyricsStore`.
3. If synced lyrics are available, use the current playback time to find the active line.
4. The next line is the next non-empty lyric line after the active line.
5. If plain unsynced lyrics are available, display the first two non-empty lines without progress following.
6. If no lyrics are available, expose an empty state such as `No Lyrics Available`.
7. If loading fails, expose a failure state such as `Lyrics Failed to Load`.

The provider requests fine progress sampling while the desktop lyrics window is visible and releases that request when the window closes.

## Error Handling

The desktop lyrics window stays lightweight and avoids embedded recovery controls. Error and empty states are text-only:

- no current track: `Not Playing`
- no lyrics: `No Lyrics Available`
- load failure: `Lyrics Failed to Load`

Changing tracks retries naturally through the normal lyrics loading path. More active recovery remains in the existing lyrics views.

If the saved window frame is invalid or off-screen, the window is centered. If `AppCoordinator.shared` is unavailable when the setting asks to show the window, the manager logs a warning and does not create the window.

## Localization

All new user-facing strings in Settings and desktop lyrics states are added to the existing localization resources. English keys are stable, and Simplified Chinese translations match the current app terminology for lyrics and settings.

## Testing

Add focused tests where the codebase supports them, or lightweight scriptable checks for pure logic:

- current and next line derivation for synced lyrics
- skipping empty lyric lines when choosing the next line
- plain unsynced lyrics display of the first two non-empty lines
- no-track, no-lyrics, and load-failure display states
- saved frame restoration only when the frame intersects a connected screen

Manual verification covers:

- Settings toggle opens and closes the desktop lyrics window immediately
- lock mode makes the window click-through
- unlocking allows the window to be moved
- moving the window persists position across relaunch
- font family and font size changes apply to the visible window
- existing main, mini player, and immersive lyrics views behave unchanged
