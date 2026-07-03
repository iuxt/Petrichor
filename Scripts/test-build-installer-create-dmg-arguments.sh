#!/usr/bin/env bash
set -euo pipefail

script="Scripts/build-installer.sh"

if rg -n 'create-dmg "\$APP_NAME\.app"' "$script" >/dev/null; then
    printf 'build-installer must pass create-dmg an output .dmg path and source folder, not the app bundle as the output.\n' >&2
    exit 1
fi

if rg -n -- '--dmg-title' "$script" >/dev/null; then
    printf 'build-installer must not use unsupported create-dmg --dmg-title option.\n' >&2
    exit 1
fi

if ! rg -n 'create-dmg --volname "\$dmg_title" "\$dmg_path" "\$export_path"' "$script" >/dev/null; then
    printf 'build-installer must call create-dmg with --volname, output .dmg path, and source folder.\n' >&2
    exit 1
fi

printf 'build-installer create-dmg argument checks passed\n'
