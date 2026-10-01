#!/usr/bin/env bash
# Unit tests for the lyrics script preference (follow app language / original /
# simplified / traditional): persistence, change notification, follow-mode
# resolution, and re-resolution when the app language itself changes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-lyrics-script-settings.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation

func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }

func freshDefaults() -> UserDefaults {
    let suite = "lyrics-script-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

actor Counter {
    var count = 0
    func increment() { count += 1 }
}

@main struct Harness {
    @MainActor static func wait(for counter: Counter, toReach target: Int) async {
        for _ in 0..<500 {
            if await counter.count >= target { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @MainActor static func main() async throws {
        // --- Resolution: follow mode reads the effective app language ---
        expect(LyricsScriptPreference.followAppLanguage.resolvedScript(for: .simplifiedChinese) == .simplified,
               "Simplified-Chinese app language must resolve to simplified lyrics")
        expect(LyricsScriptPreference.followAppLanguage.resolvedScript(for: .english) == .original,
               "English app language must resolve to original lyrics")
        expect(AppLanguage(rawValue: "zh-Hant") == nil,
               "AppLanguage has no traditional case today; resolution only sees known cases")
        expect(LyricsScriptPreference.original.resolvedScript(for: .simplifiedChinese) == .original,
               "An explicit original preference ignores the app language")
        expect(LyricsScriptPreference.simplified.resolvedScript(for: .english) == .simplified,
               "An explicit simplified preference ignores the app language")
        expect(LyricsScriptPreference.traditional.resolvedScript(for: .simplifiedChinese) == .traditional,
               "An explicit traditional preference ignores the app language")
        print("Resolution OK")

        // --- Defaults: a fresh install follows the app language ---
        let defaults = freshDefaults()
        let settings = LyricsScriptSettings(defaults: defaults)
        expect(settings.preference == .followAppLanguage, "Fresh installs must default to following the app language")
        expect(defaults.string(forKey: LyricsScriptPreference.userDefaultsKey) == nil,
               "The default must not be eagerly persisted")
        print("Default value OK")

        // --- Selection persists and notifies ---
        let changes = Counter()
        var latestObject: LyricsScriptPreference?
        let token = NotificationCenter.default.addObserver(
            forName: .lyricsScriptPreferenceDidChange, object: nil, queue: .main
        ) { note in
            latestObject = note.object as? LyricsScriptPreference
            Task { await changes.increment() }
        }
        settings.select(.simplified)
        await wait(for: changes, toReach: 1)
        expect(settings.preference == .simplified, "Selection must update the published preference")
        expect(defaults.string(forKey: LyricsScriptPreference.userDefaultsKey) == LyricsScriptPreference.simplified.rawValue,
               "Selection must persist to UserDefaults")
        expect(latestObject == .simplified, "The change notification carries the new preference")

        // Re-selecting the current value is a no-op.
        settings.select(.simplified)
        try? await Task.sleep(nanoseconds: 60_000_000)
        expect(await changes.count == 1, "Re-selecting the same preference must not notify")
        print("Selection, persistence and notification OK")

        // --- Follow mode resolves through the stored app language ---
        let chineseDefaults = freshDefaults()
        chineseDefaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.userDefaultsKey)
        chineseDefaults.set(LyricsScriptPreference.followAppLanguage.rawValue, forKey: LyricsScriptPreference.userDefaultsKey)
        expect(LyricsScriptSettings(defaults: chineseDefaults).effectiveScript == .simplified,
               "Follow mode with a Chinese app language renders simplified")

        let englishDefaults = freshDefaults()
        englishDefaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.userDefaultsKey)
        englishDefaults.set(LyricsScriptPreference.followAppLanguage.rawValue, forKey: LyricsScriptPreference.userDefaultsKey)
        expect(LyricsScriptSettings(defaults: englishDefaults).effectiveScript == .original,
               "Follow mode with an English app language renders the original script")
        print("Effective script OK")

        // --- An explicit preference does not re-notify on app language changes ---
        let fixedSettings = LyricsScriptSettings(defaults: freshDefaults())
        fixedSettings.select(.traditional)
        await wait(for: changes, toReach: 2)  // both selections have notified by now
        let fixedCount = await changes.count
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        try? await Task.sleep(nanoseconds: 80_000_000)
        expect(await changes.count == fixedCount,
               "Explicit preferences must not re-notify when the app language changes")
        print("Explicit preference ignores app language changes OK")

        // --- Follow mode re-resolves when the app language itself changes ---
        let followSettings = LyricsScriptSettings(defaults: englishDefaults)
        expect(followSettings.preference == .followAppLanguage, "Follow settings must keep following")
        try? await Task.sleep(nanoseconds: 20_000_000)  // let its observer settle
        NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        await wait(for: changes, toReach: fixedCount + 1)
        NotificationCenter.default.removeObserver(token)
        // File-language choices persist and override the default script preference.
        let fileLanguage = LyricLanguage(languageTag: "ZH_Hant")
        followSettings.selectLanguage(fileLanguage)
        expect(followSettings.languageTag == "zh-hant", "Language tags must normalize")
        expect(followSettings.preference == .traditional, "Known scripts update the settings preference")
        let restoredLanguageSettings = LyricsScriptSettings(defaults: englishDefaults)
        expect(restoredLanguageSettings.languageTag == "zh-hant", "Explicit file language must persist")
        followSettings.selectLanguage(LyricLanguage(languageTag: "en-US"))
        expect(followSettings.languageTag == "en-us", "Non-Chinese languages can be selected")
        followSettings.select(.followAppLanguage)
        expect(followSettings.languageTag == nil, "Selecting a default preference clears the explicit language")
        expect(LyricsScriptSettings(defaults: englishDefaults).languageTag == nil,
               "Clearing a language override must persist")
        followSettings.selectLanguage(.original)
        expect(followSettings.preference == .original && followSettings.languageTag == nil,
               "An untagged original language clears all overrides")
        print("All lyrics script settings tests passed")
    }
}
SWIFT

xcrun swiftc \
    Utilities/LocalizationSettings.swift \
    Utilities/LyricsScriptSettings.swift \
    Core/Lyrics/TTMLLyricsParser.swift \
    Models/Core/Lyrics.swift \
    "$TMP_DIR/Harness.swift" \
    -o "$TMP_DIR/lyrics-script-settings-test"
"$TMP_DIR/lyrics-script-settings-test"
