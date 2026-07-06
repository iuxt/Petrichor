#!/usr/bin/env bash
set -euo pipefail

resolver="Core/Artwork/ArtworkResolver.swift"
engine="Core/Metadata/MetadataEngine.swift"
readers=(Core/Metadata/CrescendoMetadataReader.swift Core/Metadata/SFBMetadataReader.swift)

if ! rg -n 'final class ArtworkResolver|static let shared = ArtworkResolver' "$resolver" >/dev/null; then
    printf 'ArtworkResolver singleton is missing.\n' >&2
    exit 1
fi

for pattern in \
  'MetadataEngine\.extractEmbeddedArtwork\(' \
  'ExternalArtworkResolver\.sameStemArtworkURL\(forAudioURL:' \
  'ExternalArtworkResolver\.genericArtworkURL\(forAudioURL:' \
  'cache\.store\(data, for: key\)'; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    printf 'ArtworkResolver missing expected pattern: %s\n' "$pattern" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
source = Path("Core/Artwork/ArtworkResolver.swift").read_text()

marker = "func artworkData(for request: ArtworkRequest) async -> Data?"
start = source.find(marker)
if start < 0:
    raise SystemExit("Missing ArtworkResolver.artworkData(for:) priority method")

brace = source.find("{", start)
if brace < 0:
    raise SystemExit("Could not parse ArtworkResolver.artworkData(for:) body")

depth = 0
end = -1
for idx in range(brace, len(source)):
    char = source[idx]
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = idx
            break

if end < 0:
    raise SystemExit("Could not parse ArtworkResolver.artworkData(for:) body")

body = source[brace + 1:end]
patterns = [
    "cachedOrEmbeddedArtwork",
    "kind: .sameStem",
    "kind: .generic"
]
positions = []
for pattern in patterns:
    idx = body.find(pattern)
    if idx < 0:
        raise SystemExit(f"Missing resolver priority marker: {pattern}")
    positions.append(idx)
if positions != sorted(positions):
    raise SystemExit("ArtworkResolver source order must be embedded, same-stem, generic")
PY

if rg -n 'TrackArtworkDownloadManager|downloadedArtworkData|downloadArtwork\(for:' "$resolver" >/dev/null; then
    printf 'ArtworkResolver still contains online artwork fallback.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\)' "$engine" >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\).*async -> Data\?' "$engine" "${readers[@]}" >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi
