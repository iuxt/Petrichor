#!/usr/bin/env bash
set -euo pipefail

if rg -n 'ArtistEntity\([^\n]*artworkData|updateArtistEntityArtwork|Artist\.Columns\.artworkData|artist\.artworkData|carryOverArtistMetadata|winner\.artworkData' Models Managers Views -g '*.swift' >/dev/null; then
    printf 'Artist artwork runtime feature is still referenced.\n' >&2
    rg -n 'ArtistEntity\([^\n]*artworkData|updateArtistEntityArtwork|Artist\.Columns\.artworkData|artist\.artworkData|carryOverArtistMetadata|winner\.artworkData' Models Managers Views -g '*.swift' >&2
    exit 1
fi
