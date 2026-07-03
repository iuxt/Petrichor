#!/usr/bin/env bash
set -euo pipefail

if rg -n 'track\.trackArtworkData\s*=\s*metadata\.artworkData|trackArtworkData\]\s*=\s*trackArtworkData|updateArtistArtwork\(|updateAlbumArtwork\(' Managers/Database/DMMetadata.swift Managers/Database/DMTrackProcessing.swift Managers/Database/DMNormalization.swift >/dev/null; then
    printf 'Scan/update code still writes artwork into database-backed fields.\n' >&2
    rg -n 'track\.trackArtworkData\s*=\s*metadata\.artworkData|trackArtworkData\]\s*=\s*trackArtworkData|updateArtistArtwork\(|updateAlbumArtwork\(' Managers/Database/DMMetadata.swift Managers/Database/DMTrackProcessing.swift Managers/Database/DMNormalization.swift >&2
    exit 1
fi

if rg -n 'Artist\.Columns\.artworkData\.set|Album\.Columns\.artworkData\.set|FullTrack\.Columns\.trackArtworkData\.set' Managers/Database >/dev/null; then
    printf 'Database code still updates artwork blob columns.\n' >&2
    rg -n 'Artist\.Columns\.artworkData\.set|Album\.Columns\.artworkData\.set|FullTrack\.Columns\.trackArtworkData\.set' Managers/Database >&2
    exit 1
fi
