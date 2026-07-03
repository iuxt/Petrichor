# App Language Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a settings-panel language selector for Follow System, English, and Simplified Chinese, with immediate SwiftUI locale refresh where supported.

**Architecture:** Add a small root-owned localization settings object that stores the selected language in `UserDefaults` and exposes an effective SwiftUI `Locale`. Inject that locale at the app scene roots, then bind a new Appearance settings picker to the shared localization object. Keep the implementation scoped to SwiftUI locale injection and avoid bundle swizzling or writes to `AppleLanguages`.

**Tech Stack:** Swift, SwiftUI, `@StateObject`, `@EnvironmentObject`, `UserDefaults`, String Catalog (`Resources/Localizable.xcstrings`), shell-script verification.

---

## File Structure

- Create `Utilities/LocalizationSettings.swift`: `AppLanguage` enum, stable storage key, effective locale mapping, and root observable settings object.
- Modify `PetrichorApp.swift`: own `LocalizationSettings`, inject it and its locale into the main and Equalizer scenes.
- Modify `Views/Settings/AppearanceTabView.swift`: add the Language picker in the Customization section and bind it to `LocalizationSettings`.
- Modify `Application/AppDelegate.swift`: register the default `appLanguage` value as `system`.
- Modify `Resources/Localizable.xcstrings`: add strings used by the new picker.
- Modify `Scripts/test-localization-format-specifiers.sh`: keep existing format checks and add focused static checks for this feature.

The project uses file-system synchronized Xcode groups for `Utilities`, `Views`, `Application`, and `Resources`, so creating `Utilities/LocalizationSettings.swift` should not require editing `Petrichor.xcodeproj/project.pbxproj`.

## Task 1: Add Failing Static Verification

**Files:**
- Modify: `Scripts/test-localization-format-specifiers.sh`

- [ ] **Step 1: Add feature-specific checks to the localization script**

Edit `Scripts/test-localization-format-specifiers.sh` so it becomes:

```bash
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
```

- [ ] **Step 2: Run the script and verify it fails**

Run:

```bash
Scripts/test-localization-format-specifiers.sh
```

Expected: FAIL with `AppLanguage enum with stable cases is missing.`

- [ ] **Step 3: Commit the failing verification**

Run:

```bash
git add Scripts/test-localization-format-specifiers.sh
git commit -m "test: cover app language setting"
```

Expected: commit succeeds and includes only `Scripts/test-localization-format-specifiers.sh`.

## Task 2: Add Root Language State and Locale Injection

**Files:**
- Create: `Utilities/LocalizationSettings.swift`
- Modify: `PetrichorApp.swift`
- Modify: `Application/AppDelegate.swift`

- [ ] **Step 1: Create the localization settings model**

Create `Utilities/LocalizationSettings.swift`:

```swift
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let userDefaultsKey = "appLanguage"

    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }
}

@MainActor
final class LocalizationSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published private(set) var appLanguage: AppLanguage

    var locale: Locale {
        appLanguage.locale
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appLanguage = AppLanguage.stored(in: defaults)
    }

    func select(_ language: AppLanguage) {
        guard language != appLanguage else { return }
        appLanguage = language
        defaults.set(language.rawValue, forKey: AppLanguage.userDefaultsKey)
    }
}
```

- [ ] **Step 2: Register the default language preference**

In `Application/AppDelegate.swift`, add the `appLanguage` default inside `registerUserDefaultsDefaults()`:

```swift
static func registerUserDefaultsDefaults() {
    let defaults: [String: Any] = [
        "closeToMenubar": true,
        "startAtLogin": false,
        "hideDuplicateTracks": true,
        "autoScanInterval": "every60Minutes",
        "colorMode": "Auto",
        "showFoldersTab": false,
        "showTrackTechnicalInfo": true,
        "tintPlaybackControls": true,
        "tintNowPlayingBackground": true,
        "playerBarBackgroundStyle": "Full width",
        "discoverUpdateInterval": "weekly",
        "discoverTrackCount": 50,
        "desktopLyricsEnabled": false,
        "desktopLyricsClickThrough": false,
        "desktopLyricsFontName": DesktopLyricsSettings.systemFontName,
        "desktopLyricsFontSize": 28.0,
        "appLanguage": AppLanguage.system.rawValue,
        MediaBackend.userDefaultsKey: true
    ]

    UserDefaults.standard.register(defaults: defaults)
}
```

- [ ] **Step 3: Inject localization state at scene roots**

In `PetrichorApp.swift`, add the state object next to the existing app coordinator state:

```swift
@StateObject private var appCoordinator: AppCoordinator
@StateObject private var localizationSettings: LocalizationSettings
```

Update `init()`:

```swift
init() {
    AppDelegate.registerUserDefaultsDefaults()
    _appCoordinator = StateObject(wrappedValue: AppCoordinator())
    _localizationSettings = StateObject(wrappedValue: LocalizationSettings())
}
```

In the `WindowGroup` root, add the object and locale environment modifiers after the existing environment objects:

```swift
ContentView()
    .environmentObject(appCoordinator.playbackManager)
    .environmentObject(appCoordinator.playbackManager.playbackProgressState)
    .environmentObject(appCoordinator.libraryManager)
    .environmentObject(appCoordinator.playlistManager)
    .environmentObject(localizationSettings)
    .environment(\.locale, localizationSettings.locale)
```

In `equalizerWindow`, add the same localization environment:

```swift
WindowGroup("Equalizer", id: "equalizer") {
    EqualizerView()
        .environmentObject(appCoordinator.playbackManager)
        .environmentObject(localizationSettings)
        .environment(\.locale, localizationSettings.locale)
}
```

- [ ] **Step 4: Run the focused script and verify the remaining failure**

Run:

```bash
Scripts/test-localization-format-specifiers.sh
```

Expected: FAIL with `Appearance settings must use the shared LocalizationSettings object.`

- [ ] **Step 5: Commit root localization state**

Run:

```bash
git add Utilities/LocalizationSettings.swift PetrichorApp.swift Application/AppDelegate.swift
git commit -m "feat: add app language locale state"
```

Expected: commit succeeds and includes only those three files.

## Task 3: Add the Settings UI and String Catalog Entries

**Files:**
- Modify: `Views/Settings/AppearanceTabView.swift`
- Modify: `Resources/Localizable.xcstrings`

- [ ] **Step 1: Bind Appearance settings to the localization object**

In `Views/Settings/AppearanceTabView.swift`, add the environment object near the top of the view:

```swift
@EnvironmentObject private var localizationSettings: LocalizationSettings
```

Add this binding helper inside `AppearanceTabView`:

```swift
private var languageSelection: Binding<AppLanguage> {
    Binding(
        get: { localizationSettings.appLanguage },
        set: { localizationSettings.select($0) }
    )
}
```

- [ ] **Step 2: Add the Language picker**

In the `Section("Customization")` block, place this row before the existing Color mode row:

```swift
Picker("Language", selection: languageSelection) {
    ForEach(AppLanguage.allCases) { language in
        Text(language.title)
            .tag(language)
    }
}
```

Update the preview at the bottom of `Views/Settings/AppearanceTabView.swift`:

```swift
#Preview {
    AppearanceTabView()
        .frame(width: 600, height: 500)
        .environmentObject(LocalizationSettings())
}
```

- [ ] **Step 3: Add string catalog entries with a structured edit**

Run this one-time structured edit from the repository root:

```bash
python3 - <<'PY'
import json
from pathlib import Path

path = Path("Resources/Localizable.xcstrings")
data = json.loads(path.read_text())
strings = data.setdefault("strings", {})

entries = {
    "Language": {
        "localizations": {
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": "语言"
                }
            }
        }
    },
    "Follow System": {
        "localizations": {
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": "跟随系统"
                }
            }
        }
    },
    "English": {
        "localizations": {
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": "English"
                }
            }
        }
    },
    "Simplified Chinese": {
        "localizations": {
            "en": {
                "stringUnit": {
                    "state": "translated",
                    "value": "简体中文"
                }
            },
            "zh-Hans": {
                "stringUnit": {
                    "state": "translated",
                    "value": "简体中文"
                }
            }
        }
    }
}

for key, value in entries.items():
    current = strings.setdefault(key, {})
    current.update(value)

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
```

- [ ] **Step 4: Run the focused localization script and verify it passes**

Run:

```bash
Scripts/test-localization-format-specifiers.sh
```

Expected: PASS with `Localization format specifier checks passed`.

- [ ] **Step 5: Commit the settings UI**

Run:

```bash
git add Views/Settings/AppearanceTabView.swift Resources/Localizable.xcstrings
git commit -m "feat: add language picker to settings"
```

Expected: commit succeeds and includes only those two files.

## Task 4: Build and Manual Verification

**Files:**
- Verify only; no planned file edits.

- [ ] **Step 1: Run the focused localization check**

Run:

```bash
Scripts/test-localization-format-specifiers.sh
```

Expected: PASS with `Localization format specifier checks passed`.

- [ ] **Step 2: Run a Debug build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: build exits with status 0.

- [ ] **Step 3: Manually verify the setting in the app**

Run the app from Xcode or the built Debug product, then verify:

- Open Settings.
- Go to Appearance.
- Change Language to `简体中文`.
- Confirm visible SwiftUI settings labels switch to Simplified Chinese without relaunching.
- Change Language to `English`.
- Confirm visible SwiftUI settings labels switch to English without relaunching.
- Change Language to `Follow System`.
- Confirm the UI follows the system locale behavior on the next SwiftUI refresh.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git status --short
git log --oneline -3
```

Expected: only unrelated pre-existing workspace changes remain unstaged, and the three new commits are visible at the top of the log.
