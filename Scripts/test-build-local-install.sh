#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fixture="$tmpdir/project with spaces"
mkdir -p "$fixture" "$tmpdir/bin" "$tmpdir/Applications"
cp "$repo_root/build.sh" "$fixture/build.sh"
export MOCK_ARGS="$tmpdir/build-args"
export MOCK_EVENTS="$tmpdir/app-events"
export MOCK_RUNNING="$tmpdir/app-running"
export MOCK_QUIT_DELAY="$tmpdir/quit-delay"
export PATH="$tmpdir/bin:$PATH"

cat > "$tmpdir/bin/xcodebuild" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$MOCK_ARGS"
if [ "${MOCK_BUILD_FAIL:-false}" = true ]; then exit 42; fi
derived_data=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -derivedDataPath ]; then derived_data="$2"; shift; fi
    shift
done
app="$derived_data/Build/Products/Release/Petrichor.app"
mkdir -p "$app/Contents/MacOS"
printf '#!/bin/bash\nexit 0\n' > "$app/Contents/MacOS/Petrichor"
chmod +x "$app/Contents/MacOS/Petrichor"
printf 'new version\n' > "$app/version"
SH

cat > "$tmpdir/bin/git" <<'SH'
#!/bin/bash
if [ "$1" = describe ]; then exit 1; fi
printf '12345678\n'
SH

cat > "$tmpdir/bin/ditto" <<'SH'
#!/bin/bash
if [ "${MOCK_COPY_FAIL:-false}" = true ] && [[ "$2" == */.Petrichor-install.*/* ]]; then exit 43; fi
/bin/cp -R "$1" "$2"
SH

cat > "$tmpdir/bin/mv" <<'SH'
#!/bin/bash
if [[ "$2" == */previous.app ]]; then
    [ ! -f "$MOCK_RUNNING" ] || exit 47
    printf 'backup\n' >> "$MOCK_EVENTS"
fi
if [[ "$1" == */.Petrichor-install.*/Petrichor.app ]]; then
    [ ! -f "$MOCK_RUNNING" ] || exit 47
    printf 'replace\n' >> "$MOCK_EVENTS"
    if [ "${MOCK_REPLACE_FAIL:-false}" = true ]; then exit 44; fi
fi
/bin/mv "$@"
SH

cat > "$tmpdir/bin/pgrep" <<'SH'
#!/bin/bash
[ "$1" = -x ] && [ "$2" = Petrichor ] || exit 48
if [ -f "$MOCK_QUIT_DELAY" ]; then
    remaining=$(cat "$MOCK_QUIT_DELAY")
    if [ "$remaining" -eq 0 ]; then
        rm -f "$MOCK_RUNNING" "$MOCK_QUIT_DELAY"
        printf 'stopped\n' >> "$MOCK_EVENTS"
    else
        printf '%s\n' "$((remaining - 1))" > "$MOCK_QUIT_DELAY"
    fi
fi
[ -f "$MOCK_RUNNING" ]
SH

cat > "$tmpdir/bin/osascript" <<'SH'
#!/bin/bash
printf 'quit\n' >> "$MOCK_EVENTS"
if [ "${MOCK_QUIT_FAIL:-false}" = true ]; then exit 49; fi
if [ "${MOCK_QUIT_STUCK:-false}" = true ]; then exit 0; fi
if [ "${MOCK_DELAY_QUIT:-false}" = true ]; then
    printf '2\n' > "$MOCK_QUIT_DELAY"
else
    rm -f "$MOCK_RUNNING"
fi
SH

cat > "$tmpdir/bin/open" <<'SH'
#!/bin/bash
printf 'launch\n' >> "$MOCK_EVENTS"
[ ! -f "$MOCK_RUNNING" ] || exit 50
[ "$(cat "$1/version")" = 'new version' ] || exit 51
if [ "${MOCK_LAUNCH_FAIL:-false}" = true ]; then exit 52; fi
SH

# Exercise the quit timeout without spending thirty seconds in the test.
printf '#!/bin/bash\nexit 0\n' > "$tmpdir/bin/sleep"

for tool in create-dmg hdiutil diskutil; do
    printf '#!/bin/bash\nprintf "Unexpected DMG tool call\\n" >&2\nexit 45\n' > "$tmpdir/bin/$tool"
done
chmod +x "$tmpdir/bin/"*

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
target="$tmpdir/Applications/Petrichor.app"
run_build() {
    : > "$MOCK_EVENTS"
    # Call from outside the repository, with spaces in both project and install paths.
    (cd "$tmpdir" && /bin/bash "$fixture/build.sh" --install-dir "$tmpdir/Applications" "$@") > "$tmpdir/output" 2>&1
}
seed_old_app() {
    rm -rf "$target"
    mkdir -p "$target"
    printf 'old version\n' > "$target/version"
    touch "$target/obsolete-file"
    touch "$MOCK_RUNNING"
}
assert_old_app() {
    [ "$(cat "$target/version")" = 'old version' ] || fail "Previous app was lost"
    [ -f "$target/obsolete-file" ] || fail "Previous app was modified"
}
assert_no_staging() {
    [ -z "$(find "$tmpdir/Applications" -name '.Petrichor-install.*' -print)" ] || fail "Install staging was not cleaned up"
}

seed_old_app
run_build
[ "$(cat "$target/version")" = 'new version' ] || fail "New app was not installed"
[ ! -f "$target/obsolete-file" ] || fail "Replacement retained files from the old app"
rg -Fx "ARCHS=$(uname -m)" "$MOCK_ARGS" >/dev/null || fail "Default architecture must match this Mac"
assert_no_staging
[ "$(cat "$MOCK_EVENTS")" = $'quit\nbackup\nreplace\nlaunch' ] || fail "Expected quit → replace → launch order"

seed_old_app
MOCK_DELAY_QUIT=true run_build
[ "$(cat "$MOCK_EVENTS")" = $'quit\nstopped\nbackup\nreplace\nlaunch' ] || fail "Replacement did not wait for shutdown"
assert_no_staging

rm -rf "$target"
run_build --universal --version 1.2.3
[ -x "$target/Contents/MacOS/Petrichor" ] || fail "First installation failed"
rg -Fx 'ARCHS=x86_64 arm64' "$MOCK_ARGS" >/dev/null || fail "Universal architectures missing"
rg -Fx 'MARKETING_VERSION=1.2.3' "$MOCK_ARGS" >/dev/null || fail "Version override missing"
assert_no_staging
[ "$(cat "$MOCK_EVENTS")" = $'replace\nlaunch' ] || fail "First installation must launch without requesting quit"

seed_old_app
run_build --no-install --intel-only
assert_old_app
[ -f "$MOCK_RUNNING" ] && [ ! -s "$MOCK_EVENTS" ] || fail "Build-only mode changed the running app"
rg -Fx 'ARCHS=x86_64' "$MOCK_ARGS" >/dev/null || fail "Intel architecture missing"
run_build --no-install --arm-only
assert_old_app
rg -Fx 'ARCHS=arm64' "$MOCK_ARGS" >/dev/null || fail "Apple Silicon architecture missing"

if MOCK_BUILD_FAIL=true run_build; then fail "Build failure returned success"; fi
assert_old_app
[ ! -s "$MOCK_EVENTS" ] || fail "Build failure quit or launched the app"
if MOCK_COPY_FAIL=true run_build; then fail "Install copy failure returned success"; fi
assert_old_app
assert_no_staging
[ ! -s "$MOCK_EVENTS" ] || fail "Copy failure quit or launched the app"
if MOCK_REPLACE_FAIL=true run_build; then fail "Install replacement failure returned success"; fi
assert_old_app
assert_no_staging
if rg -Fx 'launch' "$MOCK_EVENTS" >/dev/null; then fail "Failed replacement launched the app"; fi

seed_old_app
if MOCK_QUIT_FAIL=true run_build; then fail "Quit failure returned success"; fi
assert_old_app
assert_no_staging
[ "$(cat "$MOCK_EVENTS")" = quit ] || fail "Quit failure must prevent replacement and launch"
if MOCK_QUIT_STUCK=true run_build; then fail "Quit timeout returned success"; fi
assert_old_app
assert_no_staging
[ "$(cat "$MOCK_EVENTS")" = quit ] || fail "Quit timeout must prevent replacement and launch"

if MOCK_LAUNCH_FAIL=true run_build; then fail "Launch failure returned success"; fi
[ "$(cat "$target/version")" = 'new version' ] || fail "Launch failure must preserve the installed new app"
assert_no_staging

rm -rf "$target"
mkdir "$tmpdir/linked-app"
ln -s "$tmpdir/linked-app" "$target"
if run_build; then fail "Symlink destination was accepted"; fi
[ -L "$target" ] || fail "Symlink destination was modified"

for option in --version --install-dir --unknown; do
    if /bin/bash "$fixture/build.sh" "$option" > "$tmpdir/output" 2>&1; then
        fail "Invalid argument was accepted: $option"
    fi
done
[ -z "$(find "$fixture/build" -name '*.dmg' -print)" ] || fail "Local build created a DMG"
printf 'Local build and install checks passed\n'
