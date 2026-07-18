#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! rg -n "$pattern" "$SERVICE" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local message="$2"
    if rg -n "$pattern" "$SERVICE" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern 'actor SFBTrackMetadataFileService' 'Metadata file access must be actor-isolated.'
require_pattern 'static let writableExtensions: Set<String>' 'The writable extension allowlist is missing.'
require_pattern '"mp3".*"m4a".*"flac".*"wav"' 'The common writable formats are missing.'
require_pattern 'let metadata = audioFile.metadata' 'Writes must mutate the existing metadata object.'
require_pattern 'try audioFile.writeMetadata\(\)' 'The service must call SFBAudioEngine writeMetadata().'
require_pattern 'try loadSnapshot\(target: target\)' 'The service must reopen the file after writing.'
require_pattern 'patch.mismatchedFields\(in: verified.tags\)' 'The service must verify every dirty field.'
require_pattern 'func preflightWrite\(' 'The service must preflight before playback is suspended.'
require_pattern 'startAccessingSecurityScopedResource' 'The service must honor sandbox security scope.'
require_pattern 'stopAccessingSecurityScopedResource' 'Security scope must be balanced.'
reject_pattern 'AudioMetadata\(\)' 'Replacing the whole metadata object can erase untouched tags.'

printf '%s\n' 'Track metadata file service checks passed'
