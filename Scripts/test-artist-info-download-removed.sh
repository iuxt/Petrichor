#!/usr/bin/env bash
set -euo pipefail

if [[ -e "Managers/ArtistBioManager.swift" ]]; then
    printf 'ArtistBioManager.swift should be removed with artist image/bio downloading.\n' >&2
    exit 1
fi

for removed_file in "Views/Components/ArtistImageSheet.swift"; do
    if [[ -e "$removed_file" ]]; then
        printf '%s should be removed with artist image downloading.\n' "$removed_file" >&2
        exit 1
    fi
done

if rg -n "ArtistBioManager|artistInfoFetchEnabled|fetchMissingArtistImages|searchAllImages|Fetch artist image and bio|Automatically download artist photos and bios|Update image|Choose Artist Image|Searching for images" \
    Managers Views Models Core Resources PetrichorApp.swift >/dev/null
then
    printf 'Artist image/bio download wiring or UI text is still present.\n' >&2
    exit 1
fi

if rg -n "LASTFM_API_KEY|TMDB_READ_ACCESS_TOKEN|MusicBrainz|TMDB|LastFM|Wikidata|lrclib" Managers/ArtistBioManager.swift Views/Components/ArtistImageSheet.swift 2>/dev/null; then
    printf 'Artist metadata download provider code is still present.\n' >&2
    exit 1
fi

printf 'Artist image/bio downloading removed\n'
