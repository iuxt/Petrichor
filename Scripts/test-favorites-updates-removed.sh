#!/usr/bin/env bash
set -euo pipefail

mode="${1:-all}"

run_favorite_checks() {
    local swift_paths=(
        Application
        Managers
        Models
        Views
        Utilities
        PetrichorApp.swift
    )

    local favorite_pattern='isFavorite|toggleFavorite|trackFavoriteStatusChanged|Add to Favorites|Remove from Favorites|ToggleFavoriteIntent|FavoriteButton|loveSyncEnabled|trackLoveStatusChanged|setLoveStatus|DefaultPlaylists\.favorites|sortableIsFavorite'

    if rg -n "$favorite_pattern" "${swift_paths[@]}" \
        -g '*.swift' \
        -g '!Managers/Database/DatabaseMigration.swift' >/dev/null; then
        printf 'Favorite feature hooks remain in production Swift files.\n' >&2
        rg -n "$favorite_pattern" "${swift_paths[@]}" \
            -g '*.swift' \
            -g '!Managers/Database/DatabaseMigration.swift' >&2
        exit 1
    fi

    if rg -n '"(Add to Favorites|Remove from Favorites|Favorites|Favorite|Is Favorite|No Favorite Songs|Sync favorites as Loved tracks|Toggle Favorite for Current Track|Tracks you favorite in Petrichor will be loved on Last\.fm|Favorites or unfavorites the current track in Petrichor\.|Mark songs as favorites to see them here)"' Resources/Localizable.xcstrings >/dev/null; then
        printf 'Favorite localization keys remain.\n' >&2
        exit 1
    fi

    if rg -n 'BOOLEAN is_favorite|DefaultPlaylists\.favorites|field: "isFavorite"' README.md Views Models Managers Utilities PetrichorApp.swift \
        -g '!Managers/Database/DatabaseMigration.swift' >/dev/null; then
        printf 'Favorite docs, previews, or runtime references remain.\n' >&2
        exit 1
    fi
}

run_update_checks() {
    local update_pattern='Sparkle|SPUUpdater|SPUStandardUpdaterController|SPUUpdaterDelegate|updaterController|checkForUpdates|Check for Updates|automaticUpdatesEnabled|SUPublicEDKey|SUFeedURL|SUEnableAutomaticChecks|SUEnableInstallerLauncherService|sparkle-project|"identity" : "sparkle"'

    if rg -n "$update_pattern" \
        Application Views Utilities PetrichorApp.swift Configuration/Info.plist Petrichor.xcodeproj README.md ACKNOWLEDGEMENTS.md Resources/Localizable.xcstrings .github/workflows/ci.yml >/dev/null; then
        printf 'Update-checking hooks or docs remain.\n' >&2
        rg -n "$update_pattern" \
            Application Views Utilities PetrichorApp.swift Configuration/Info.plist Petrichor.xcodeproj README.md ACKNOWLEDGEMENTS.md Resources/Localizable.xcstrings .github/workflows/ci.yml >&2
        exit 1
    fi
}

run_migration_checks() {
    if ! rg -n 'v15_remove_track_favorites' Managers/Database/DatabaseMigration.swift >/dev/null; then
        printf 'Migration v15_remove_track_favorites is missing.\n' >&2
        exit 1
    fi

    if rg -n 'is_favorite|idx_tracks_is_favorite' Managers/Database/DMSetup.swift >/dev/null; then
        printf 'Fresh database setup still creates favorite schema.\n' >&2
        exit 1
    fi

    if rg -n 'Columns\.isFavorite|isFavorite' Models/Core/Track.swift Models/Core/FullTrack.swift Managers/Database/DMTrackUpdate.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Playlist/PMSmartPlaylistEvaluator.swift >/dev/null; then
        printf 'Favorite model or query references remain.\n' >&2
        exit 1
    fi
}

case "$mode" in
    favorite)
        run_favorite_checks
        ;;
    update)
        run_update_checks
        ;;
    migration)
        run_migration_checks
        ;;
    all)
        run_favorite_checks
        run_update_checks
        run_migration_checks
        ;;
    *)
        printf 'Usage: %s [favorite|update|migration|all]\n' "$0" >&2
        exit 2
        ;;
esac

printf 'Favorites and update-checking removal checks passed (%s)\n' "$mode"
