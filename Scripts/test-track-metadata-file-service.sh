#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift"
WRITER="$ROOT_DIR/Core/Metadata/ID3TrackMetadataWriter.swift"
BRIDGE_HEADER="$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.h"
ATOMIC_REPLACER="$ROOT_DIR/Core/Metadata/AtomicMetadataFileReplacer.swift"

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
require_pattern 'AtomicMetadataFileReplacer\.replace' 'Metadata writes must mutate and verify a sibling copy before atomically replacing the source file.'
require_pattern 'temporaryTarget' 'Metadata writers must receive the temporary copy, never the live decoder source.'
require_pattern 'func preflightWrite\(' 'The service must preflight before playback is suspended.'
require_pattern 'startAccessingSecurityScopedResource' 'The service must honor sandbox security scope.'
require_pattern 'stopAccessingSecurityScopedResource' 'Security scope must be balanced.'
require_pattern 'let resolvedParent =' 'Atomic replacement must preflight the resolved parent directory.'
require_pattern 'replacementSupport' 'Unsafe replacement targets must be rejected before copy-on-write replacement.'
require_pattern 'case \.multipleHardLinks' 'Hard-linked files need a distinct preflight reason.'
require_pattern 'case \.unsupportedVolume' 'Volumes without atomic swap support need a distinct preflight reason.'
reject_pattern 'AudioMetadata\(\)' 'Replacing the whole metadata object can erase untouched tags.'
reject_pattern '"dsf".*"dff"' 'Unverified DSF/DSDIFF ID3 writers must not be advertised as writable.'

if [[ ! -f "$ATOMIC_REPLACER" ]] ||
   ! rg -n 'copyItem.*sourceURL.*temporaryURL' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'renamex_np' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'RENAME_SWAP' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'SwapSnapshot' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'fcopyfile' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'fstat' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'verifyPinnedCandidate' "$ATOMIC_REPLACER" >/dev/null 2>&1 ||
   ! rg -n 'swapPathsStillIdentify' "$ATOMIC_REPLACER" >/dev/null 2>&1; then
    printf '%s\n' 'The same-directory copy-on-write atomic file replacer is missing.' >&2
    exit 1
fi

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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-atomic-metadata.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

private enum HarnessError: Error {
    case expectedFailure
    case assertion(String)
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw HarnessError.assertion(message)
    }
}

private func bytes(_ value: String) -> Data {
    Data(value.utf8)
}

@main
struct AtomicMetadataFileReplacerHarness {
    static func main() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "petrichor-atomic-metadata-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("track.mp3")
        try bytes("old-audio-and-tags").write(to: sourceURL)
        let oldInode = try inode(of: sourceURL)
        let oldReader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? oldReader.close() }
        var verificationCount = 0

        try AtomicMetadataFileReplacer.replace(
            sourceURL,
            mutate: { temporaryURL in
                try bytes("new-audio-and-tags").write(to: temporaryURL)
            },
            verify: { candidateURL in
                verificationCount += 1
                try require(
                    try Data(contentsOf: candidateURL) ==
                        bytes("new-audio-and-tags"),
                    "Both verification boundaries must inspect the candidate."
                )
            }
        )

        try require(
            try Data(contentsOf: sourceURL) == bytes("new-audio-and-tags"),
            "New readers must see the verified replacement."
        )
        try require(
            try oldReader.readToEnd() == bytes("old-audio-and-tags"),
            "An existing decoder handle must remain on the old inode."
        )
        try require(
            try inode(of: sourceURL) != oldInode,
            "Replacement must swap the inode instead of mutating the live file."
        )
        try require(
            verificationCount == 2,
            "The candidate must be verified before and after the atomic swap."
        )

        do {
            try AtomicMetadataFileReplacer.replace(
                sourceURL,
                mutate: { temporaryURL in
                    try bytes("unverified").write(to: temporaryURL)
                },
                verify: { _ in
                    throw HarnessError.expectedFailure
                }
            )
            throw HarnessError.assertion(
                "A failed verification must abort replacement."
            )
        } catch HarnessError.expectedFailure {
            try require(
                try Data(contentsOf: sourceURL) == bytes("new-audio-and-tags"),
                "A failed mutation must leave the source unchanged."
            )
        }

        do {
            try AtomicMetadataFileReplacer.replace(
                sourceURL,
                mutate: { temporaryURL in
                    try bytes("candidate-before-race").write(to: temporaryURL)
                },
                verify: { candidateURL in
                    try bytes("changed-during-verification").write(
                        to: candidateURL
                    )
                }
            )
            throw HarnessError.assertion(
                "A candidate changed during verification must be rejected."
            )
        } catch let error as NSError {
            try require(
                error.domain == NSPOSIXErrorDomain &&
                    error.code == Int(EBUSY),
                "Verification-boundary mutation must fail with EBUSY."
            )
        }
        try require(
            try Data(contentsOf: sourceURL) == bytes("new-audio-and-tags"),
            "Candidate mutation must leave the source unchanged."
        )

        let heldWriterURL = directory.appendingPathComponent(
            "held-writer.mp3"
        )
        try bytes("AAAAAAAAAAAAAAAA").write(to: heldWriterURL)
        let heldWriter = try FileHandle(forWritingTo: heldWriterURL)
        var heldWriterVerificationCount = 0
        do {
            try AtomicMetadataFileReplacer.replace(
                heldWriterURL,
                mutate: { temporaryURL in
                    try bytes("candidate-output").write(to: temporaryURL)
                },
                verify: { _ in
                    heldWriterVerificationCount += 1
                    if heldWriterVerificationCount == 2 {
                        try heldWriter.seek(toOffset: 0)
                        try heldWriter.write(
                            contentsOf: bytes("BBBBBBBBBBBBBBBB")
                        )
                        try heldWriter.synchronize()
                    }
                }
            )
            throw HarnessError.assertion(
                "A displaced original changed through an open FD must win."
            )
        } catch let error as NSError {
            try require(
                error.domain == NSPOSIXErrorDomain &&
                    error.code == Int(EBUSY),
                "A displaced open-FD update must fail with EBUSY."
            )
        }
        try heldWriter.close()
        try require(
            try Data(contentsOf: heldWriterURL) ==
                bytes("BBBBBBBBBBBBBBBB"),
            "Rollback must preserve the open-FD writer's authoritative bytes."
        )

        let publicWriterURL = directory.appendingPathComponent(
            "public-writer.mp3"
        )
        try bytes("public-original-data").write(to: publicWriterURL)
        var publicWriterVerificationCount = 0
        do {
            try AtomicMetadataFileReplacer.replace(
                publicWriterURL,
                mutate: { temporaryURL in
                    try bytes("app-candidate-data").write(to: temporaryURL)
                },
                verify: { candidateURL in
                    publicWriterVerificationCount += 1
                    if publicWriterVerificationCount == 2 {
                        try bytes("external-public-data").write(
                            to: candidateURL
                        )
                    }
                }
            )
            throw HarnessError.assertion(
                "A public-path candidate write must not be rolled back."
            )
        } catch let error as NSError {
            try require(
                error.domain == NSPOSIXErrorDomain &&
                    error.code == Int(EBUSY),
                "A public-path candidate conflict must fail with EBUSY."
            )
        }
        try require(
            try Data(contentsOf: publicWriterURL) ==
                bytes("external-public-data"),
            "The external public-path writer must remain authoritative."
        )
        let preservedFiles = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let preservedOriginalExists = preservedFiles.contains { url in
            url.lastPathComponent.hasPrefix(".petrichor-metadata-") &&
                (try? Data(contentsOf: url)) == bytes("public-original-data")
        }
        try require(
            preservedOriginalExists,
            "A public-path conflict must preserve the displaced original."
        )

        let hardLinkURL = directory.appendingPathComponent("hard-link.mp3")
        try fileManager.linkItem(at: sourceURL, to: hardLinkURL)
        try require(
            AtomicMetadataFileReplacer.replacementSupport(for: sourceURL) ==
                .multipleHardLinks,
            "Hard-linked files must be rejected before replacement."
        )
        do {
            try AtomicMetadataFileReplacer.replace(
                sourceURL,
                mutate: { temporaryURL in
                    try bytes("must-not-replace").write(to: temporaryURL)
                },
                verify: { _ in }
            )
            throw HarnessError.assertion(
                "A hard-linked file must not be silently split."
            )
        } catch let error as NSError {
            try require(
                error.domain == NSPOSIXErrorDomain &&
                    error.code == Int(EMLINK),
                "Hard-linked replacement must fail specifically with EMLINK."
            )
        }
        try require(
            try Data(contentsOf: sourceURL) == bytes("new-audio-and-tags") &&
                Data(contentsOf: hardLinkURL) ==
                    bytes("new-audio-and-tags"),
            "Rejecting a hard link must leave every alias unchanged."
        )
        try fileManager.removeItem(at: hardLinkURL)

        do {
            try AtomicMetadataFileReplacer.replace(
                sourceURL,
                mutate: { temporaryURL in
                    try bytes("candidate-tags").write(to: temporaryURL)
                    try bytes("concurrent-external-change").write(
                        to: sourceURL
                    )
                },
                verify: { _ in }
            )
            throw HarnessError.assertion(
                "A source changed during save must not be overwritten."
            )
        } catch {
            try require(
                try Data(contentsOf: sourceURL) ==
                    bytes("concurrent-external-change"),
                "A concurrent source update must remain authoritative."
            )
        }

        let longNameURL = directory.appendingPathComponent(
            String(repeating: "x", count: 240) + ".mp3"
        )
        try bytes("long-name-old").write(to: longNameURL)
        try AtomicMetadataFileReplacer.replace(
            longNameURL,
            mutate: { temporaryURL in
                try bytes("long-name-new").write(to: temporaryURL)
            },
            verify: { _ in }
        )
        try require(
            try Data(contentsOf: longNameURL) == bytes("long-name-new"),
            "Valid long source names must not overflow the temporary name."
        )

        let symlinkURL = directory.appendingPathComponent("linked-track.mp3")
        try fileManager.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: sourceURL
        )
        let alternateURL = directory.appendingPathComponent("alternate.mp3")
        try bytes("alternate-target").write(to: alternateURL)
        do {
            try AtomicMetadataFileReplacer.replace(
                symlinkURL,
                mutate: { temporaryURL in
                    try bytes("stale-symlink-candidate").write(
                        to: temporaryURL
                    )
                    try fileManager.removeItem(at: symlinkURL)
                    try fileManager.createSymbolicLink(
                        at: symlinkURL,
                        withDestinationURL: alternateURL
                    )
                },
                verify: { _ in }
            )
            throw HarnessError.assertion(
                "A retargeted symlink must abort replacement."
            )
        } catch {
            try require(
                try Data(contentsOf: sourceURL) ==
                    bytes("concurrent-external-change"),
                "Retargeting a symlink must not alter its old target."
            )
            try require(
                try Data(contentsOf: alternateURL) ==
                    bytes("alternate-target"),
                "Retargeting a symlink must not alter its new target."
            )
        }
        try fileManager.removeItem(at: symlinkURL)
        try fileManager.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: sourceURL
        )
        try AtomicMetadataFileReplacer.replace(
            symlinkURL,
            mutate: { temporaryURL in
                try bytes("symlink-safe-tags").write(to: temporaryURL)
            },
            verify: { _ in }
        )
        let symlinkValues = try symlinkURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        try require(
            symlinkValues.isSymbolicLink == true,
            "Editing through a symlink must preserve the symlink itself."
        )
        try require(
            try Data(contentsOf: sourceURL) == bytes("symlink-safe-tags"),
            "Editing through a symlink must replace its resolved target."
        )
    }

    private static func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw HarnessError.assertion("Missing inode attribute.")
        }
        return inode.uint64Value
    }
}
SWIFT

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/PetrichorClangModuleCache}" \
SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/PetrichorSwiftModuleCache}" \
swiftc \
    -parse-as-library \
    "$ATOMIC_REPLACER" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/atomic-metadata-file-replacer"
"$TMP_DIR/atomic-metadata-file-replacer"

printf '%s\n' 'Track metadata file service checks passed'
