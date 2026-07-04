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

if ! rg -n 'refreshMainMenuLocalizedTitles\(\)' PetrichorApp.swift >/dev/null; then
    printf '%s\n' 'PetrichorApp must refresh the macOS main menu when app language changes.' >&2
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
SWIFT

swiftc Utilities/LocalizationSettings.swift "$tmpdir/main.swift" -o "$tmpdir/test-app-language-localized-strings"
"$tmpdir/test-app-language-localized-strings" "$tmpdir/Test.bundle"

printf '%s\n' 'App language localized string checks passed'
