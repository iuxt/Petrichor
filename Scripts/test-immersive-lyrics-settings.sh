#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMMERSIVE_VIEW="$ROOT_DIR/Views/Immersive/ImmersiveView.swift"
TRACK_LYRICS_VIEW="$ROOT_DIR/Views/Main/TrackLyricsView.swift"
SETTINGS_CONTROLS="$ROOT_DIR/Views/Components/LyricsFontSettingsControls.swift"
APPEARANCE_SETTINGS="$ROOT_DIR/Views/Settings/AppearanceTabView.swift"
APP_DELEGATE="$ROOT_DIR/Application/AppDelegate.swift"
LOCALIZATION="$ROOT_DIR/Resources/Localizable.xcstrings"

rg -n '@AppStorage\("immersiveLyricsFontName"\)' "$IMMERSIVE_VIEW" >/dev/null
rg -n '@AppStorage\("immersiveLyricsFontSize"\)' "$IMMERSIVE_VIEW" >/dev/null
rg -n 'fontName: immersiveLyricsFontName == LyricsFontSettings\.systemFontName' "$IMMERSIVE_VIEW" >/dev/null
rg -n 'fontSize: CGFloat\(immersiveLyricsFontSize\) \* layout\.scale' "$IMMERSIVE_VIEW" >/dev/null
if rg -n 'showingLyricsSettings|lyricsSettingsPopover' "$IMMERSIVE_VIEW" >/dev/null; then
    printf 'Immersive lyrics settings must live in the app Settings window, not the playback interface.\n' >&2
    exit 1
fi

rg -n '@AppStorage\("immersiveLyricsFontName"\)' "$APPEARANCE_SETTINGS" >/dev/null
rg -n '@AppStorage\("immersiveLyricsFontSize"\)' "$APPEARANCE_SETTINGS" >/dev/null
rg -n 'Section\("Full Screen Lyrics"\)' "$APPEARANCE_SETTINGS" >/dev/null
rg -n 'fontName: \$immersiveLyricsFontName' "$APPEARANCE_SETTINGS" >/dev/null
rg -n 'fontSize: \$immersiveLyricsFontSize' "$APPEARANCE_SETTINGS" >/dev/null

rg -n 'var fontName: String\? = nil' "$TRACK_LYRICS_VIEW" >/dev/null
rg -n 'fontName: fontName' "$TRACK_LYRICS_VIEW" >/dev/null
rg -n '\.custom\(fontName, size: fontSize\)' "$TRACK_LYRICS_VIEW" >/dev/null

rg -n 'NSFontManager\.shared\.availableFontFamilies' "$SETTINGS_CONTROLS" >/dev/null
rg -n 'LyricsFontSettingsControls' "$SETTINGS_CONTROLS" >/dev/null

rg -n '"immersiveLyricsFontName": LyricsFontSettings\.systemFontName' "$APP_DELEGATE" >/dev/null
rg -n '"immersiveLyricsFontSize": 20\.0' "$APP_DELEGATE" >/dev/null
jq -e '.strings["Full Screen Lyrics"].localizations["zh-Hans"].stringUnit.value == "全屏歌词"' \
    "$LOCALIZATION" >/dev/null

printf 'Immersive lyrics settings checks passed\n'
