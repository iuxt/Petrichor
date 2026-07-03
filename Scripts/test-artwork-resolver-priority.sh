#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'final class ArtworkResolver|static let shared = ArtworkResolver' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver singleton is missing.\n' >&2
    exit 1
fi

if ! rg -n 'ExternalArtworkResolver\.artworkURL\(forAudioURL:.*candidates:' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver must reuse ExternalArtworkResolver priority.\n' >&2
    exit 1
fi

if ! rg -n 'MetadataEngine\.extractEmbeddedArtwork\(' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver must fall back to embedded artwork.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\)' Core/Metadata/MetadataEngine.swift >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\).*async -> Data\?' Core/Metadata/MetadataEngine.swift Core/Metadata/CrescendoMetadataReader.swift Core/Metadata/SFBMetadataReader.swift >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi
