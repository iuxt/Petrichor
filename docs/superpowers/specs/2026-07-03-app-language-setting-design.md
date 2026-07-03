# App Language Setting Design

## Goal

Add a language setting to Petrichor's settings panel. The app currently supports English and Simplified Chinese through `Resources/Localizable.xcstrings`; users should be able to choose:

- Follow System
- English
- Simplified Chinese

The selected language should update SwiftUI UI immediately where the framework supports locale-driven refresh. The feature should not require a restart, should not auto-quit or relaunch the app, and should not write system-wide language preferences.

## Current Context

Settings are implemented under `Views/Settings/`. Existing preferences use `@AppStorage` and app defaults are registered in `Application/AppDelegate.swift`.

The app's string catalog has `sourceLanguage` set to `en` and includes `zh-Hans` translations. There is no existing in-app language manager or runtime bundle override. Most SwiftUI text uses localizable literals, while some generated labels, menus, alerts, and manager messages use `String(localized:)` or AppKit APIs.

## Recommended Approach

Use a small app-level language preference model and inject the selected `Locale` into SwiftUI through the environment.

This approach is low risk and fits the existing codebase:

- It works naturally with SwiftUI `Text` and string catalogs.
- It keeps the preference in `UserDefaults`, like the rest of settings.
- It avoids `Bundle` swizzling or writing `AppleLanguages`, both of which have wider compatibility and behavior risks.
- It accepts a clear boundary: some AppKit or precomputed strings may not switch instantly.

## User Experience

The Appearance settings tab will add a Language row in the Customization section. The control will present three choices:

- Follow System
- English
- 简体中文

A compact `Picker` is preferred over a segmented control because the labels are mixed-language and may be wider after localization. Changing the selection saves immediately and triggers SwiftUI locale refresh. No restart prompt is shown.

## Architecture

Add an `AppLanguage` enum with stable raw values:

- `system`
- `english`
- `simplifiedChinese`

The enum exposes the user-facing display name and the locale identifier needed by SwiftUI. Unknown stored values fall back to `system`.

Add a small observable localization settings object, for example `LocalizationSettings`, responsible for:

- Reading the stored `appLanguage` value from `UserDefaults`.
- Publishing the effective `Locale` for SwiftUI.
- Handling the system language case with `Locale.autoupdatingCurrent`.
- Providing an update path when the setting changes.

`PetrichorApp` owns this object as a root-level state object and injects its locale into the main window and Equalizer window using `.environment(\.locale, ...)`.

## Data Flow

1. The user changes the language in `AppearanceTabView`.
2. The selection is stored in `UserDefaults` under `appLanguage`.
3. The root localization settings object observes or is notified of the change.
4. The root SwiftUI scenes receive the updated locale.
5. SwiftUI views that depend on localized text re-render in the selected language.

## Boundaries

The feature provides best-effort immediate language switching for SwiftUI surfaces. It does not guarantee instant refresh for:

- Existing AppKit menus.
- Already visible `NSAlert` instances.
- Status/menu bar items already built from `String(localized:)`.
- Text generated and cached before the setting changed.

Those surfaces should use the selected language when rebuilt or reopened. The implementation should not add bundle swizzling, global method replacement, or writes to `AppleLanguages`.

## Localization

New user-facing strings must be added to `Resources/Localizable.xcstrings`, including:

- Language
- Follow System
- English
- Simplified Chinese

The visible picker label for Simplified Chinese can use `简体中文` so the option is recognizable even when the current UI language is English.

## Defaults

Register the default `appLanguage` value as `system` in `AppDelegate.registerUserDefaultsDefaults()`. Existing users with no stored value will follow the system language.

## Testing

Verification should include:

- A focused shell check that confirms the language enum, default registration, settings row, root environment locale injection, and string catalog entries exist.
- `Scripts/test-localization-format-specifiers.sh` because the string catalog is edited.
- A Debug build with `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build` when feasible.

Manual verification should confirm that selecting English or Simplified Chinese updates visible SwiftUI settings text without relaunching, and that Follow System returns to the system locale behavior.
