#!/usr/bin/env bash
set -euo pipefail

require_pattern() {
    local pattern="$1"
    local file="$2"
    local message="$3"

    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern 'enum AppLanguage: String, CaseIterable, Identifiable' \
    'Utilities/LocalizationSettings.swift' \
    'AppLanguage enum with stable cases is missing.'
require_pattern 'static let userDefaultsKey = "appLanguage"' \
    'Utilities/LocalizationSettings.swift' \
    'AppLanguage must define the appLanguage UserDefaults key.'
require_pattern 'case system' \
    'Utilities/LocalizationSettings.swift' \
    'AppLanguage must include the system case.'
require_pattern 'case english' \
    'Utilities/LocalizationSettings.swift' \
    'AppLanguage must include the english case.'
require_pattern 'case simplifiedChinese' \
    'Utilities/LocalizationSettings.swift' \
    'AppLanguage must include the simplifiedChinese case.'
require_pattern 'final class LocalizationSettings: ObservableObject' \
    'Utilities/LocalizationSettings.swift' \
    'LocalizationSettings observable object is missing.'
require_pattern 'Locale\.autoupdatingCurrent' \
    'Utilities/LocalizationSettings.swift' \
    'LocalizationSettings must map Follow System to Locale.autoupdatingCurrent.'
require_pattern 'Locale\(identifier: "en"\)' \
    'Utilities/LocalizationSettings.swift' \
    'LocalizationSettings must map English to the en locale.'
require_pattern 'Locale\(identifier: "zh-Hans"\)' \
    'Utilities/LocalizationSettings.swift' \
    'LocalizationSettings must map Simplified Chinese to the zh-Hans locale.'
require_pattern '@StateObject private var localizationSettings' \
    'PetrichorApp.swift' \
    'PetrichorApp must own LocalizationSettings at the root.'
require_pattern '\.environmentObject\(localizationSettings\)' \
    'PetrichorApp.swift' \
    'PetrichorApp must inject LocalizationSettings into SwiftUI.'
require_pattern '\.environment\(\\\.locale, localizationSettings\.locale\)' \
    'PetrichorApp.swift' \
    'PetrichorApp must inject the selected locale into SwiftUI.'
require_pattern '@EnvironmentObject private var localizationSettings: LocalizationSettings' \
    'Views/Settings/AppearanceTabView.swift' \
    'Appearance settings must use the shared LocalizationSettings object.'
require_pattern 'Picker\("Language", selection: languageSelection\)' \
    'Views/Settings/AppearanceTabView.swift' \
    'Appearance settings must expose a Language picker.'
require_pattern '"appLanguage": AppLanguage\.system\.rawValue' \
    'Application/AppDelegate.swift' \
    'AppDelegate must register appLanguage default as system.'

python3 - <<'PY'
import json
import re
from pathlib import Path

strings = json.loads(Path("Resources/Localizable.xcstrings").read_text())["strings"]

required_language_keys = {
    "Language": "语言",
    "Follow System": "跟随系统",
    "English": "English",
    "Simplified Chinese": "简体中文",
}

missing = []
for key, zh_value in required_language_keys.items():
    entry = strings.get(key)
    if not entry:
        missing.append(f"{key}: missing key")
        continue
    value = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {}).get("value")
    if value != zh_value:
        missing.append(f"{key}: zh-Hans must be {zh_value!r}, got {value!r}")

if missing:
    raise SystemExit("Language setting localization entries are incomplete:\n" + "\n".join(missing))

specifier_pattern = re.compile(r"%(?:(\d+)\$)?(?:[-+#0 ]*\d*(?:\.\d+)?)*(?:@|lld|ld|d|f|s)")


def specifiers(value):
    return [match.group(0) for match in specifier_pattern.finditer(value)]


def specifier_type(specifier):
    return specifier.rsplit("$", 1)[-1].lstrip("%")


errors = []
for key, entry in strings.items():
    key_specs = specifiers(key)
    if len(key_specs) < 2:
        continue

    key_types = [specifier_type(spec) for spec in key_specs]
    for locale, data in entry.get("localizations", {}).items():
        value = data.get("stringUnit", {}).get("value", "")
        value_specs = specifiers(value)
        value_types = [specifier_type(spec) for spec in value_specs]

        if value_types == key_types:
            continue

        has_positions = all("$" in spec for spec in value_specs)
        if value_types and not has_positions:
            errors.append(f"{locale}: {key!r} -> {value!r}")

if errors:
    raise SystemExit(
        "Localized strings that reorder format arguments must use positional specifiers:\n"
        + "\n".join(errors)
    )

print("Localization format specifier checks passed")
PY
