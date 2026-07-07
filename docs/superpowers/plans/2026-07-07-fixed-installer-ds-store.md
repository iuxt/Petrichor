# Fixed Installer .DS_Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make local and GitHub Actions DMG packaging use the same prebuilt Finder `.DS_Store` layout asset.

**Architecture:** `Scripts/build-installer.sh` owns DMG source staging, so it will also own staging the fixed `.DS_Store` asset and regenerating it on explicit request. Shell checks will enforce that normal packaging always uses the fixed layout file and skips Finder AppleScript.

**Tech Stack:** Bash, macOS `diskutil`, Homebrew `create-dmg`, repository shell checks.

## Global Constraints

- Add the fixed layout asset at `Scripts/assets/installer.DS_Store`.
- Regular local builds and CI builds must not regenerate `.DS_Store`.
- Both local and CI builds must pass `--skip-jenkins` to `create-dmg`.
- The fallback `diskutil image create` path must stage the same `.DS_Store`.
- The `create-dmg` path must pass the same `.DS_Store` through `--add-file` because Homebrew `create-dmg` removes `.DS_Store` from its initial source folder.
- If `Scripts/assets/installer.DS_Store` is missing during normal packaging, warn and continue creating a usable DMG.
- Regeneration must fail clearly if the temporary DMG does not produce a `.DS_Store`.

---

### Task 1: Fixed Layout Staging

**Files:**
- Modify: `Scripts/build-installer.sh`
- Modify: `Scripts/test-build-installer-create-dmg-arguments.sh`
- Modify: `Scripts/test-build-warning-cleanliness.sh`

**Interfaces:**
- Consumes: existing `prepare_dmg_source(app_source, dmg_source)` helper.
- Produces: `INSTALLER_DS_STORE` constant and `stage_installer_ds_store(target_dir)` helper.

- [ ] **Step 1: Write the failing shell checks**

Add these checks to `Scripts/test-build-installer-create-dmg-arguments.sh` after the existing background checks:

```bash
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

if rg -n 'if \[ "\$\{CI:-false\}" = true \]; then' "$script" >/dev/null; then
    printf 'build-installer must not limit --skip-jenkins to CI; local and CI builds must use the fixed .DS_Store path.\n' >&2
    exit 1
fi
```

Add this check to `Scripts/test-build-warning-cleanliness.sh` near the existing `--skip-jenkins` and DMG checks:

```bash
if ! rg -n 'stage_installer_ds_store "\$dmg_dir"' "$build_script" >/dev/null; then
    printf 'build-installer fallback DMG creation must stage the fixed installer .DS_Store.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run checks to verify they fail**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
```

Expected: FAIL with `build-installer must default to the repository installer .DS_Store and allow an environment override.`

Run:

```bash
Scripts/test-build-warning-cleanliness.sh
```

Expected: FAIL with `build-installer fallback DMG creation must stage the fixed installer .DS_Store.`

- [ ] **Step 3: Implement fixed layout staging**

In `Scripts/build-installer.sh`, add this constant after `INSTALLER_BACKGROUND`:

```bash
INSTALLER_DS_STORE="${PETRICHOR_INSTALLER_DS_STORE:-$SCRIPT_DIR/assets/installer.DS_Store}"
```

Add this helper after `prepare_dmg_source()` or before it:

```bash
stage_installer_ds_store() {
    local target_dir="$1"

    if [ -f "$INSTALLER_DS_STORE" ]; then
        cp "$INSTALLER_DS_STORE" "$target_dir/.DS_Store"
    else
        warning "Installer .DS_Store not found at $INSTALLER_DS_STORE"
    fi
}
```

Call the helper inside `prepare_dmg_source()` after background staging:

```bash
    stage_installer_ds_store "$dmg_source"
```

Add the fixed file to `create-dmg` after the writable image is mounted:

```bash
    if [ "${CREATE_DMG_ALLOW_APPLESCRIPT:-false}" != true ] && [ -f "$INSTALLER_DS_STORE" ]; then
        args+=(--add-file ".DS_Store" "$INSTALLER_DS_STORE" 0 0)
    fi
```

Change `create_dmg_with_layout()` so normal packaging adds `--skip-jenkins`, while explicit `.DS_Store` regeneration can allow AppleScript:

```bash
    if [ "${CREATE_DMG_ALLOW_APPLESCRIPT:-false}" != true ]; then
        args+=(--skip-jenkins)
    fi
```

Remove this conditional block:

```bash
    if [ "${CI:-false}" = true ]; then
        args+=(--skip-jenkins)
    fi
```

In each fallback path that creates `dmg_dir`, call the helper after the app and Applications link are staged:

```bash
        stage_installer_ds_store "$dmg_dir"
```

- [ ] **Step 4: Run checks to verify they pass**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
Scripts/test-build-warning-cleanliness.sh
```

Expected: both scripts print their `passed` messages and exit 0.

---

### Task 2: Layout Asset Regeneration

**Files:**
- Modify: `Scripts/build-installer.sh`
- Modify: `Scripts/test-build-installer-create-dmg-arguments.sh`

**Interfaces:**
- Consumes: `create_dmg_with_layout(dmg_title, dmg_path, dmg_source)` and `prepare_dmg_source(app_source, dmg_source)`.
- Produces: `GENERATE_DS_STORE` flag and `generate_installer_ds_store()` command path.

- [ ] **Step 1: Write the failing shell checks**

Add these checks to `Scripts/test-build-installer-create-dmg-arguments.sh` near the other `create-dmg` checks:

```bash
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
```

- [ ] **Step 2: Run check to verify it fails**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
```

Expected: FAIL with `build-installer must expose an explicit --generate-ds-store maintainer mode.`

- [ ] **Step 3: Implement explicit regeneration mode**

Add a global flag with the other mode defaults:

```bash
GENERATE_DS_STORE=false
```

Extend argument parsing with:

```bash
        --generate-ds-store)
            GENERATE_DS_STORE=true
            LOCAL_PACKAGE=true
            BYPASS_NOTARY=true
            ;;
```

Add a helper:

```bash
generate_installer_ds_store() {
    local built_app="$BUILD_DIR/${APP_NAME}.app"
    local dmg_source="$BUILD_DIR/dmg-source-ds-store"
    local dmg_path="$BUILD_DIR/${APP_NAME}-ds-store-layout.dmg"
    local mount_dir=""
    local mounted_ds_store=""

    if [ ! -d "$built_app" ]; then
        error "Cannot generate installer .DS_Store because $built_app does not exist"
        return 1
    fi

    prepare_dmg_source "$built_app" "$dmg_source"
    rm -f "$dmg_source/.DS_Store"

    CREATE_DMG_ALLOW_APPLESCRIPT=true create_dmg_with_layout "$APP_NAME Layout" "$dmg_path" "$dmg_source" || {
        error "create-dmg failed while generating installer .DS_Store"
        return 1
    }

    mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-ds-store.XXXXXX")"
    diskutil image attach --mountPoint "$mount_dir" --nobrowse "$dmg_path" >/dev/null || {
        rm -rf "$mount_dir"
        error "Failed to mount generated layout DMG"
        return 1
    }

    mounted_ds_store="$mount_dir/.DS_Store"
    if [ ! -f "$mounted_ds_store" ]; then
        diskutil eject "$mount_dir" >/dev/null 2>&1 || true
        rm -rf "$mount_dir"
        error "Generated layout DMG did not contain .DS_Store"
        return 1
    fi

    cp "$mounted_ds_store" "$INSTALLER_DS_STORE"
    diskutil eject "$mount_dir" >/dev/null
    rm -rf "$mount_dir" "$dmg_source" "$dmg_path"
    log "Installer .DS_Store regenerated at $INSTALLER_DS_STORE"
}
```

Change `create_dmg_with_layout()` so it only skips AppleScript unless explicitly allowed:

```bash
        --app-drop-link "$DMG_APPLICATIONS_ICON_X" "$DMG_APPLICATIONS_ICON_Y"
    )

    if [ "${CREATE_DMG_ALLOW_APPLESCRIPT:-false}" != true ]; then
        args+=(--skip-jenkins)
    fi
```

In the main flow after the app has been built/copied to `BUILD_DIR/${APP_NAME}.app`, branch to `generate_installer_ds_store` when `GENERATE_DS_STORE=true`.

- [ ] **Step 4: Run check to verify it passes**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
```

Expected: prints `build-installer create-dmg argument checks passed`.

---

### Task 3: Commit Fixed Layout Asset

**Files:**
- Create: `Scripts/assets/installer.DS_Store`
- Modify: `Scripts/test-build-installer-create-dmg-arguments.sh`

**Interfaces:**
- Consumes: `INSTALLER_DS_STORE`.
- Produces: committed binary layout asset.

- [ ] **Step 1: Write the failing asset check**

Add this check to `Scripts/test-build-installer-create-dmg-arguments.sh`:

```bash
if [ ! -f "Scripts/assets/installer.DS_Store" ]; then
    printf 'repository must include Scripts/assets/installer.DS_Store for deterministic DMG layout.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run check to verify it fails**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
```

Expected: FAIL with `repository must include Scripts/assets/installer.DS_Store for deterministic DMG layout.`

- [ ] **Step 3: Generate or seed the layout asset**

Preferred local regeneration after the script supports it:

```bash
Scripts/build-installer.sh --local --generate-ds-store
```

If Finder automation cannot run in the current environment, seed the asset from a previously generated installer `.DS_Store` and document that limitation in the final response.

- [ ] **Step 4: Run targeted checks**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
Scripts/test-build-warning-cleanliness.sh
```

Expected: both scripts pass.

---

### Task 4: Final Verification

**Files:**
- Read: `Scripts/build-installer.sh`
- Read: `Scripts/test-build-installer-create-dmg-arguments.sh`
- Read: `Scripts/test-build-warning-cleanliness.sh`

**Interfaces:**
- Consumes: all prior task outputs.
- Produces: verified packaging change ready for review.

- [ ] **Step 1: Run all packaging-related shell checks**

Run:

```bash
Scripts/test-build-installer-create-dmg-arguments.sh
Scripts/test-build-warning-cleanliness.sh
```

Expected: both pass.

- [ ] **Step 2: Run git diff review**

Run:

```bash
git diff -- Scripts/build-installer.sh Scripts/test-build-installer-create-dmg-arguments.sh Scripts/test-build-warning-cleanliness.sh docs/superpowers/specs/2026-07-07-fixed-installer-ds-store-design.md docs/superpowers/plans/2026-07-07-fixed-installer-ds-store.md
git diff --stat
```

Expected: only packaging script, packaging checks, fixed layout asset, and docs changed.
