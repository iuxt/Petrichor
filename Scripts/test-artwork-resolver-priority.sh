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
  'TrackArtworkDownloadManager\.shared\.downloadArtwork\(for:' \
  'cache\.store\(data, for: key\)'; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    printf 'ArtworkResolver missing expected pattern: %s\n' "$pattern" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
source = Path("Core/Artwork/ArtworkResolver.swift").read_text()
patterns = [
    "cachedOrEmbeddedArtwork",
    "sameStemArtworkURL",
    "genericArtworkURL",
    "downloadArtwork(for:"
]
positions = []
for pattern in patterns:
    idx = source.find(pattern)
    if idx < 0:
        raise SystemExit(f"Missing resolver priority marker: {pattern}")
    positions.append(idx)
if positions != sorted(positions):
    raise SystemExit("ArtworkResolver source order must be embedded, same-stem, generic, online")
PY

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\)' "$engine" >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\).*async -> Data\?' "$engine" "${readers[@]}" >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi
