#!/usr/bin/env bash
set -euo pipefail

script="Scripts/build-installer.sh"
workflow=".github/workflows/release.yml"

if rg -n 'npm install --global create-dmg' "$workflow" >/dev/null; then
    printf 'release workflow must not install the incompatible npm create-dmg package; build-installer uses the Homebrew/create-dmg CLI syntax.\n' >&2
    exit 1
fi

if ! rg -n 'brew install create-dmg' "$workflow" >/dev/null; then
    printf 'release workflow must install the Homebrew create-dmg formula.\n' >&2
    exit 1
fi

if rg -n 'create-dmg "\$APP_NAME\.app"' "$script" >/dev/null; then
    printf 'build-installer must pass create-dmg an output .dmg path and source folder, not the app bundle as the output.\n' >&2
    exit 1
fi

if rg -n -- '--dmg-title' "$script" >/dev/null; then
    printf 'build-installer must not use unsupported create-dmg --dmg-title option.\n' >&2
    exit 1
fi

if ! rg -n 'INSTALLER_BACKGROUND="\$\{PETRICHOR_INSTALLER_BACKGROUND:-\$SCRIPT_DIR/\.\./Resources/dmg\.svg\}"' "$script" >/dev/null; then
    printf 'build-installer must default to the repository installer SVG background and allow an environment override.\n' >&2
    exit 1
fi

if ! rg -n 'cp "\$INSTALLER_BACKGROUND" "\$dmg_source/\.background/install\.svg"' "$script" >/dev/null; then
    printf 'build-installer must stage the SVG background inside the DMG source folder.\n' >&2
    exit 1
fi

if ! rg -n 'INSTALLER_DS_STORE="\$\{PETRICHOR_INSTALLER_DS_STORE:-\$SCRIPT_DIR/assets/installer\.DS_Store\}"' "$script" >/dev/null; then
    printf 'build-installer must default to the repository installer .DS_Store and allow an environment override.\n' >&2
    exit 1
fi

if ! rg -n 'stage_installer_ds_store "\$dmg_source"' "$script" >/dev/null; then
    printf 'build-installer must stage the fixed installer .DS_Store in create-dmg source folders.\n' >&2
    exit 1
fi

if ! rg -n 'cp "\$INSTALLER_DS_STORE" "\$target_dir/\.DS_Store"' "$script" >/dev/null; then
    printf 'build-installer must copy the fixed installer .DS_Store to the DMG root.\n' >&2
    exit 1
fi

if ! rg -n -- '--add-file "\.DS_Store" "\$INSTALLER_DS_STORE" 0 0' "$script" >/dev/null; then
    printf 'build-installer must pass the fixed installer .DS_Store through create-dmg --add-file so create-dmg does not delete it from the source folder.\n' >&2
    exit 1
fi

if [ ! -f "Scripts/assets/installer.DS_Store" ]; then
    printf 'repository must include Scripts/assets/installer.DS_Store for deterministic DMG layout.\n' >&2
    exit 1
fi

if rg -n 'ln -s /Applications "\$dmg_source/Applications"' "$script" >/dev/null; then
    printf 'build-installer must let create-dmg --app-drop-link create the Applications link instead of pre-staging it.\n' >&2
    exit 1
fi

if ! rg -n -- '--background "\$dmg_source/\.background/install\.svg"' "$script" >/dev/null; then
    printf 'build-installer must pass the staged SVG background to create-dmg.\n' >&2
    exit 1
fi

if ! rg -n -- '--window-size "\$DMG_WINDOW_WIDTH" "\$DMG_WINDOW_HEIGHT"' "$script" >/dev/null; then
    printf 'build-installer must set the create-dmg window size.\n' >&2
    exit 1
fi

if ! rg -n -- '--icon "\$APP_NAME\.app" "\$DMG_APP_ICON_X" "\$DMG_APP_ICON_Y"' "$script" >/dev/null; then
    printf 'build-installer must set the Petrichor app icon position.\n' >&2
    exit 1
fi

if ! rg -n -- '--app-drop-link "\$DMG_APPLICATIONS_ICON_X" "\$DMG_APPLICATIONS_ICON_Y"' "$script" >/dev/null; then
    printf 'build-installer must add an Applications drop link at the configured position.\n' >&2
    exit 1
fi

if ! rg -n -- '--skip-jenkins' "$script" >/dev/null; then
    printf 'build-installer must pass --skip-jenkins to create-dmg on CI to avoid Finder AppleScript hangs.\n' >&2
    exit 1
fi

if rg -n 'if \[ "\$\{CI:-false\}" = true \]; then' "$script" >/dev/null; then
    printf 'build-installer must not limit --skip-jenkins to CI; local and CI builds must use the fixed .DS_Store path.\n' >&2
    exit 1
fi

if ! rg -n 'create_dmg_with_layout "\$dmg_title" "\$dmg_path" "\$dmg_source"' "$script" >/dev/null; then
    printf 'build-installer must call create-dmg through the layout helper with output .dmg path and staged source folder.\n' >&2
    exit 1
fi

if ! rg -n 'create_dmg_bin="\$\(create_dmg_command\)"' "$script" >/dev/null; then
    printf 'build-installer must resolve create-dmg through the compatibility wrapper.\n' >&2
    exit 1
fi

if ! rg -n 'compatible_create_dmg_available' "$script" >/dev/null; then
    printf 'build-installer must verify the installed create-dmg command supports the Homebrew/create-dmg CLI before using layout arguments.\n' >&2
    exit 1
fi

if ! rg -n -- '--generate-ds-store' "$script" >/dev/null; then
    printf 'build-installer must expose an explicit --generate-ds-store maintainer mode.\n' >&2
    exit 1
fi

if ! rg -n 'generate_installer_ds_store\(\)' "$script" >/dev/null; then
    printf 'build-installer must implement a fixed .DS_Store regeneration helper.\n' >&2
    exit 1
fi

if ! rg -n 'cp "\$mounted_ds_store" "\$INSTALLER_DS_STORE"' "$script" >/dev/null; then
    printf 'build-installer regeneration must copy the mounted DMG .DS_Store into the repository asset.\n' >&2
    exit 1
fi

if ! rg -n 'diskutil eject "\\\$\{DEV_NAME\}"' "$script" >/dev/null; then
    printf 'build-installer must patch deprecated create-dmg hdiutil detach calls to diskutil eject.\n' >&2
    exit 1
fi

if rg -n '^[[:space:]]+create-dmg ' "$script" | rg -v 'create-dmg --help' >/dev/null; then
    printf 'build-installer must not call create-dmg directly; use create_dmg_command instead.\n' >&2
    exit 1
fi

printf 'build-installer create-dmg argument checks passed\n'
