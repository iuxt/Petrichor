#!/usr/bin/env bash
set -euo pipefail

allowed_file='Utilities/LocalizationSettings.swift'

if ! rg -n 'appLocalized keyAndValue: String\.LocalizationValue' "$allowed_file" >/dev/null; then
    printf '%s\n' 'App-language-aware String(appLocalized:) initializer is missing.' >&2
    exit 1
fi

if ! rg -n 'static var currentLanguage' "$allowed_file" >/dev/null; then
    printf '%s\n' 'LocalizationSettings must expose the currently selected app language.' >&2
    exit 1
fi

if ! rg -n 'localizationSettings\.\$appLanguage' PetrichorApp.swift >/dev/null; then
    printf '%s\n' 'PetrichorApp must observe app language changes to refresh non-view UI.' >&2
    exit 1
fi

if ! rg -n 'MainMenuLocalizer\.refresh\(\)' PetrichorApp.swift >/dev/null; then
    printf '%s\n' 'PetrichorApp must refresh the macOS main menu when app language changes.' >&2
    exit 1
fi

if [[ ! -f Utilities/MainMenuLocalizer.swift ]]; then
    printf '%s\n' 'MainMenuLocalizer must centralize macOS main menu language refresh outside SwiftUI view lifecycle.' >&2
    exit 1
fi

if ! rg -n 'MainMenuLocalizer\.refresh' Application/AppDelegate.swift >/dev/null; then
    printf '%s\n' 'AppDelegate must refresh the macOS main menu after launch, not only from SwiftUI views.' >&2
    exit 1
fi

if ! rg -n 'name: \.appLanguageDidChange' Application/AppDelegate.swift >/dev/null; then
    printf '%s\n' 'AppDelegate must observe appLanguageDidChange so the macOS menu bar switches immediately.' >&2
    exit 1
fi

if ! rg -n 'static let appLanguageDidChange' Utilities/LocalizationSettings.swift >/dev/null; then
    printf '%s\n' 'LocalizationSettings must publish an appLanguageDidChange notification for AppKit surfaces.' >&2
    exit 1
fi

if ! rg -n 'NotificationCenter\.default\.post\(name: \.appLanguageDidChange' Utilities/LocalizationSettings.swift >/dev/null; then
    printf '%s\n' 'LocalizationSettings.select must post appLanguageDidChange after saving the new language.' >&2
    exit 1
fi

if ! rg -n 'name: \.appLanguageDidChange' Managers/MenuBarManager.swift >/dev/null; then
    printf '%s\n' 'MenuBarManager must observe appLanguageDidChange directly.' >&2
    exit 1
fi

if ! rg -n 'func refreshMenu\(\)' Managers/MenuBarManager.swift >/dev/null; then
    printf '%s\n' 'MenuBarManager must expose a menu refresh hook for language changes.' >&2
    exit 1
fi

if ! rg -n '@EnvironmentObject private var localizationSettings: LocalizationSettings' Views/Settings/SettingsView.swift >/dev/null; then
    printf '%s\n' 'SettingsView must observe LocalizationSettings so visible settings text refreshes.' >&2
    exit 1
fi

if ! rg -n '\.environment\(\\\.locale, localizationSettings\.locale\)' Views/Settings/SettingsView.swift >/dev/null; then
    printf '%s\n' 'SettingsView must inject the selected locale into its own sheet content.' >&2
    exit 1
fi

if ! rg -n '\.id\(localizationSettings\.appLanguage\.id\)' Views/Settings/SettingsView.swift >/dev/null; then
    printf '%s\n' 'SettingsView must force its localized content subtree to refresh when appLanguage changes.' >&2
    exit 1
fi

if ! rg -n '@EnvironmentObject private var localizationSettings: LocalizationSettings' Views/Main/ContentView.swift >/dev/null; then
    printf '%s\n' 'ContentView must observe LocalizationSettings so main-window text refreshes immediately.' >&2
    exit 1
fi

if ! rg -n '\.environment\(\\\.locale, localizationSettings\.locale\)' Views/Main/ContentView.swift >/dev/null; then
    printf '%s\n' 'ContentView must inject the selected locale into its own content subtree.' >&2
    exit 1
fi

if ! rg -n '\.id\(localizationSettings\.appLanguage\.id\)' Views/Main/ContentView.swift >/dev/null; then
    printf '%s\n' 'ContentView must force its localized content subtree to refresh when appLanguage changes.' >&2
    exit 1
fi

if ! rg -n 'private func infoButton\(isPresented: Binding<Bool>, text: String\.LocalizationValue\)' Views/Settings/LibraryTabView.swift >/dev/null; then
    printf '%s\n' 'Library settings help popovers must take String.LocalizationValue text so question-mark descriptions are resolved against the in-app language setting.' >&2
    exit 1
fi

settings_popover_required_uses=(
    'Views/Settings/AppearanceTabView.swift|String(appLocalized: "Shows small badges under the playing track for its audio details like codec (FLAC, MP3, etc.), bitrate, sample rate, and channels.")'
    'Views/Settings/GeneralTabView.swift|String(appLocalized: "Our newer engine for playing your music. With it on, you may notice:")'
    'Views/Settings/GeneralTabView.swift|String(appLocalized: "Turn it off to switch back to the classic engine. Your music and library stay exactly the same either way.")'
    'Views/Settings/GeneralTabView.swift|private func engineInfoPoint(_ text: String.LocalizationValue)'
    'Views/Settings/LibraryTabView.swift|String(appLocalized: text)'
)

for requirement in "${settings_popover_required_uses[@]}"; do
    file="${requirement%%|*}"
    pattern="${requirement#*|}"
    if ! rg -n -F "$pattern" "$file" >/dev/null; then
        printf 'Settings question-mark popover text must be resolved with String(appLocalized:) for app-language changes: %s\n' "$requirement" >&2
        exit 1
    fi
done

if rg -n 'Text\("(Our newer engine|Turn it off to switch back|Shows small badges)' Views/Settings/GeneralTabView.swift Views/Settings/AppearanceTabView.swift >/dev/null; then
    printf '%s\n' 'Settings question-mark popover text must not rely on Text string-literal localization inside popover presentation boundaries.' >&2
    exit 1
fi

command_literal_uses="$(
    rg -n '\bCommandMenu\("[^"]+"\)|\bWindowGroup\("[^"]+"|\bLabel\("[^"]+"|\bText\("[^"]+"|\bButton\("[^"]+"' PetrichorApp.swift \
        || true
)"

if [[ -n "$command_literal_uses" ]]; then
    printf '%s\n' 'PetrichorApp command/menu labels must use String(appLocalized:) so the macOS menu bar follows the in-app language setting:' >&2
    printf '%s\n' "$command_literal_uses" >&2
    exit 1
fi

for key in File View Window Services Hide "Hide Petrichor" "Hide Others" "Show All"; do
    if ! rg -n "^    \"${key}\":" Resources/Localizable.xcstrings >/dev/null; then
        printf 'Localizable.xcstrings must include the standard macOS menu key: %s\n' "$key" >&2
        exit 1
    fi
done

python3 - <<'PY'
import json
from pathlib import Path

strings = json.loads(Path("Resources/Localizable.xcstrings").read_text())["strings"]
required_library_help = {
    "Hold the ⌘ key while clicking Refresh for a forced deep re-scan of all metadata.": "单击“刷新”时按住 ⌘ 键，可强制深度重新扫描所有元数据。",
    "Removes references to library data that no longer exists on disk and compacts the database to reclaim space.": "移除磁盘上已不存在的资料库数据引用，并压缩数据库以回收空间。",
    "Stores generated cover files outside the database. Petrichor trims this cache automatically when it grows past its size limit.": "将生成的封面文件存储在数据库外。当缓存超过大小限制时，Petrichor 会自动清理。",
    "Removes all folders, tracks, playlists, and pinned items. Use the checkbox in the confirmation dialog to optionally reset app preferences.": "移除所有文件夹、曲目、播放列表和固定项目。可在确认对话框中勾选复选框，以同时重置应用偏好设置。",
}

missing = []
for key, zh_value in required_library_help.items():
    entry = strings.get(key)
    if not entry:
        missing.append(f"{key}: missing key")
        continue
    value = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {}).get("value")
    if value != zh_value:
        missing.append(f"{key}: zh-Hans must be {zh_value!r}, got {value!r}")

if missing:
    raise SystemExit("Library settings help popover localization entries are incomplete:\n" + "\n".join(missing))
PY

bare_uses="$(
    rg -n 'String\(localized:' --glob '*.swift' \
        | awk -F: -v allowed="$allowed_file" '$1 != allowed { print }' \
        || true
)"

if [[ -n "$bare_uses" ]]; then
    printf '%s\n' 'Use String(appLocalized:) so explicit localized strings follow the in-app language setting:' >&2
    printf '%s\n' "$bare_uses" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import AppKit
import Foundation

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])
let enURL = bundleURL.appendingPathComponent("en.lproj", isDirectory: true)
let zhURL = bundleURL.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
try FileManager.default.createDirectory(at: enURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: zhURL, withIntermediateDirectories: true)
try """
"Language" = "Language";
"%lld songs" = "%lld songs";
""".write(to: enURL.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
try """
"Language" = "语言";
"%lld songs" = "%lld 首歌曲";
""".write(to: zhURL.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)

guard let bundle = Bundle(url: bundleURL) else {
    fatalError("Failed to create test bundle")
}

UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)
defer {
    UserDefaults.standard.removeObject(forKey: AppLanguage.userDefaultsKey)
}

let language = String(appLocalized: "Language", bundle: bundle)
if language != "语言" {
    fputs("Expected app-localized string to use zh-Hans bundle, got \(language)\n", stderr)
    exit(1)
}

let songCount = 3
let songs = String(appLocalized: "\(songCount) songs", bundle: bundle)
if songs != "3 首歌曲" {
    fputs("Expected app-localized interpolation to use zh-Hans bundle, got \(songs)\n", stderr)
    exit(1)
}

UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.userDefaultsKey)

let menu = NSMenu()
let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
fileItem.submenu = NSMenu(title: "文件")
menu.addItem(fileItem)

let playbackItem = NSMenuItem(title: "播放", action: nil, keyEquivalent: "")
playbackItem.submenu = NSMenu(title: "播放")
menu.addItem(playbackItem)

let appItem = NSMenuItem(title: "Petrichor Dev", action: nil, keyEquivalent: "")
let appSubmenu = NSMenu(title: "Petrichor Dev")
let hideItem = NSMenuItem(title: "隐藏 Petrichor Dev", action: nil, keyEquivalent: "")
let quitItem = NSMenuItem(title: "退出 Petrichor Dev", action: nil, keyEquivalent: "")
appSubmenu.addItem(hideItem)
appSubmenu.addItem(quitItem)
appItem.submenu = appSubmenu
menu.addItem(appItem)

MainMenuLocalizer.refresh(menu: menu)

if fileItem.title != "File" || fileItem.submenu?.title != "File" {
    fputs("Expected Chinese File menu title to switch to English, got \(fileItem.title)\n", stderr)
    exit(1)
}

if playbackItem.title != "Playback" || playbackItem.submenu?.title != "Playback" {
    fputs("Expected Chinese Playback menu title to switch to English, got \(playbackItem.title)\n", stderr)
    exit(1)
}

if hideItem.title != "Hide Petrichor Dev" {
    fputs("Expected app-named Hide menu item to switch to English, got \(hideItem.title)\n", stderr)
    exit(1)
}

if quitItem.title != "Quit Petrichor Dev" {
    fputs("Expected app-named Quit menu item to switch to English, got \(quitItem.title)\n", stderr)
    exit(1)
}
SWIFT

swiftc Utilities/LocalizationSettings.swift Utilities/MainMenuLocalizer.swift "$tmpdir/main.swift" -o "$tmpdir/test-app-language-localized-strings"
"$tmpdir/test-app-language-localized-strings" "$tmpdir/Test.bundle"

printf '%s\n' 'App language localized string checks passed'
