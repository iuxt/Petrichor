#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift"
WRITER="$ROOT_DIR/Core/Metadata/ID3TrackMetadataWriter.swift"
BRIDGE_HEADER="$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.h"

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
require_pattern 'ID3TrackMetadataWriter\.probe' 'Writer selection must inspect actual ID3-carrier content.'
require_pattern 'case \.mpeg, \.wave, \.aiff, \.trueAudio' 'Every verified selective ID3 carrier must use the bridge.'
require_pattern 'try ID3TrackMetadataWriter\.write' 'ID3 carriers must use the selective writer.'
require_pattern '\.unsafeID3Carrier' 'Unverified ID3 carriers must be made read-only.'
require_pattern 'case \.nativeMetadata' 'SFB fallback requires a positively identified native container.'
require_pattern 'case \.none, \.unsafeID3Carrier' 'Unknown content must be read-only for every extension.'
require_pattern 'private func writeNonID3Metadata' 'The non-ID3 SFBAudioEngine path must stay isolated.'
require_pattern 'let metadata = audioFile.metadata' 'Non-ID3 writes must mutate the existing metadata object.'
require_pattern 'try audioFile.writeMetadata\(\)' 'Non-ID3 formats must retain SFBAudioEngine writeMetadata().'
require_pattern 'try loadSnapshot\(target: target\)' 'The service must reopen the file after writing.'
require_pattern 'patch.mismatchedFields\(in: verified.tags\)' 'The service must verify every dirty field.'
require_pattern 'func preflightWrite\(' 'The service must preflight before playback is suspended.'
require_pattern 'startAccessingSecurityScopedResource' 'The service must honor sandbox security scope.'
require_pattern 'stopAccessingSecurityScopedResource' 'Security scope must be balanced.'
reject_pattern 'AudioMetadata\(\)' 'Replacing the whole metadata object can erase untouched tags.'
reject_pattern '"dsf".*"dff"' 'Unverified DSF/DSDIFF ID3 writers must not be advertised as writable.'

if [[ ! -f "$WRITER" ]]; then
    printf '%s\n' 'The Swift selective ID3 writer is missing.' >&2
    exit 1
fi

if ! rg -n 'PTID3ProbeContainerAtPath' "$WRITER" >/dev/null 2>&1; then
    printf '%s\n' 'The Swift writer must call the content-probing C bridge.' >&2
    exit 1
fi

if [[ ! -f "$BRIDGE_HEADER" ]] ||
   ! rg -n 'PTID3WriteMetadataAtPath' "$BRIDGE_HEADER" >/dev/null 2>&1; then
    printf '%s\n' 'The selective ID3 C ABI is missing.' >&2
    exit 1
fi

printf '%s\n' 'Track metadata file service checks passed'
