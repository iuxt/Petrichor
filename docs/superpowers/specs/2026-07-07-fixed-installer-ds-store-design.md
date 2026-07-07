# Fixed Installer .DS_Store Design

## Goal

Make local and GitHub Actions DMG packaging use the same prebuilt Finder layout instead of running Finder AppleScript during every build.

## Current Behavior

`Scripts/build-installer.sh` uses Homebrew `create-dmg` when available. `create-dmg` creates a writable intermediate DMG, mounts it, optionally runs Finder AppleScript to set the window layout, waits for Finder to write `.DS_Store`, unmounts the image, then converts it into the final compressed DMG.

The current CI path passes `--skip-jenkins` only when `CI=true`, which avoids the AppleScript step on GitHub Actions. Local builds can still run the AppleScript path, so local and CI packaging can differ.

## Proposed Behavior

Add a repository-owned layout asset at `Scripts/assets/installer.DS_Store`. `build-installer.sh` will stage that file into the root of every fallback DMG source folder as `.DS_Store`.

For the `create-dmg` path, the script will also pass the fixed file through `create-dmg --add-file ".DS_Store" "$INSTALLER_DS_STORE" 0 0`. Homebrew `create-dmg` deletes `.DS_Store` from the initial source folder before creating its writable image, so relying only on source-folder staging would lose the fixed layout.

Both local and CI builds will pass `--skip-jenkins` to `create-dmg`. This makes `create-dmg` package the already-staged layout file instead of asking Finder to generate one at build time.

The fallback `diskutil image create` path will also stage the same `.DS_Store`, so the packaging result is consistent whether `create-dmg` is available or not.

## Regeneration

The fixed layout file is a binary asset and is not reviewable as text. To keep it maintainable, add an explicit regeneration entry point that is only intended for local maintainer use. The regeneration flow may run `create-dmg` without `--skip-jenkins`, mount a temporary DMG, let Finder write `.DS_Store`, copy the resulting file to `Scripts/assets/installer.DS_Store`, and clean up temporary output.

Regular local builds and CI builds will not regenerate `.DS_Store`.

## Error Handling

If `Scripts/assets/installer.DS_Store` is missing during normal packaging, the script should warn and continue creating a usable DMG. This avoids blocking local unsigned packaging if the asset is accidentally absent, while tests should still enforce that the repository contains and stages the file.

Regeneration should fail clearly if the temporary DMG does not produce a `.DS_Store`.

## Testing

Update shell checks to cover these packaging invariants:

- the fixed `.DS_Store` path is declared under `Scripts/assets`;
- normal packaging stages it as `.DS_Store` for fallback DMG creation;
- normal `create-dmg` packaging passes it via `--add-file`;
- normal `create-dmg` calls always include `--skip-jenkins`;
- fallback `diskutil image create` paths also stage the fixed layout file;
- the wrapper still patches modern macOS `create-dmg` issues such as random `TMPDIR` mount points and `diskutil eject`.
