#!/usr/bin/env bash
# Regression: a track imported while its file was still an undownloaded
# cloud-sync placeholder (SynologyDrive etc.) stores duration 0 and empty
# tags. Placeholder hydration does not change mtime, so the mtime-based
# skip in processFile never re-parses the file and the player shows 0:00
# as the total duration. The scan must force a re-parse for such records.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROCESSING="$ROOT_DIR/Managers/Database/DMTrackProcessing.swift"
HELPERS="$ROOT_DIR/Utilities/HelperUtils.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

# The healing gate must run before the mtime-based skip so a zero-duration
# record is re-parsed even when the file has not been modified.
require_pattern "$PROCESSING" \
    'hardRefresh \|\| HelperUtils\.needsMetadataHealing\(existingFullTrack\.duration\)[\s\S]*?if let cached = modificationDates\[fileURL\]' \
    'processFile must force a metadata re-parse for zero-duration records before the mtime skip.'

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-duration-healing.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/Stubs.swift" <<'SWIFT'
import Foundation

extension String {
    init(appLocalized key: String) { self = key }
}

enum StringFormat {
    static let mmss = "%d:%02d"
    static let hhmmss = "%d:%02d:%02d"
}
SWIFT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// A record whose parse failed during import (placeholder file, read error)
// must be healed: missing, zero, negative, NaN, and infinite durations count.
expect(HelperUtils.needsMetadataHealing(nil), "A missing duration must need healing")
expect(HelperUtils.needsMetadataHealing(0), "A zero duration must need healing")
expect(HelperUtils.needsMetadataHealing(-5), "A negative duration must need healing")
expect(HelperUtils.needsMetadataHealing(.nan), "A NaN duration must need healing")
expect(HelperUtils.needsMetadataHealing(.infinity), "An infinite duration must need healing")

// Healthy durations — including sub-second ones — must not trigger re-parsing.
expect(!HelperUtils.needsMetadataHealing(221.257), "A real duration must not need healing")
expect(!HelperUtils.needsMetadataHealing(0.5), "A sub-second duration must not need healing")

print("Zero-duration healing checks passed")
SWIFT

xcrun swiftc \
    "$TMP_DIR/Stubs.swift" "$HELPERS" "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/test-healing"
"$TMP_DIR/test-healing"
