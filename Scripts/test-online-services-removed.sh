#!/usr/bin/env bash
set -euo pipefail

removed_files=(
  "Managers/ScrobbleManager.swift"
  "Managers/LyricsManager.swift"
  "Managers/TrackArtworkDownloadManager.swift"
  "Managers/ArtistImageDownloadManager.swift"
  "Views/Settings/IntegrationsTabView.swift"
  "Utilities/URLSchemeHandler.swift"
  "Utilities/KeychainManager.swift"
  "Core/LyricsSidecarWriter.swift"
  "Core/Artwork/TrackArtworkSidecarWriter.swift"
)

for removed_file in "${removed_files[@]}"; do
  if [[ -e "$removed_file" ]]; then
    printf '%s should be removed with online music services.\n' "$removed_file" >&2
    exit 1
  fi
done

removed_asset_dirs=(
  "Resources/Assets.xcassets/logo-lastfm.imageset"
  "Resources/Assets.xcassets/logo-musicbrainz.imageset"
  "Resources/Assets.xcassets/logo-tmdb.imageset"
  "Resources/Assets.xcassets/logo-wikidata.imageset"
)

for removed_asset_dir in "${removed_asset_dirs[@]}"; do
  if [[ -e "$removed_asset_dir" ]]; then
    printf '%s should be removed with online music services.\n' "$removed_asset_dir" >&2
    exit 1
  fi
done

if rg -n 'ScrobbleManager|LyricsManager|TrackArtworkDownloadManager|ArtistImageDownloadManager|IntegrationsTabView|URLSchemeHandler|KeychainManager|LyricsSidecarWriter|TrackArtworkSidecarWriter|lastfmUsername|lastfmAvatarData|scrobblingEnabled|onlineLyricsEnabled|trackArtworkDownloadEnabled|artistImageDownloadEnabled|lastfm-callback|LASTFM_API_KEY|LASTFM_SHARED_SECRET|TMDB_READ_ACCESS_TOKEN|Fetch lyrics from internet when unavailable|Fetch artwork from internet when unavailable|Download artist images to music folders|Lyrics & Metadata|Track your listening history on Last\.fm|Connect your Last\.fm account|Disconnected from Last\.fm|Connected to Last\.fm|Failed to connect to Last\.fm|Last\.fm API|Last\.fm authorization|Last\.fm error|download missing lyrics|downloaded \.lrc|Download track lyrics from the internet|internet lyric|online lyric|Network access' \
  Application Managers Views Core Utilities Models Configuration Resources/Localizable.xcstrings PetrichorApp.swift AGENTS.md README.md ACKNOWLEDGEMENTS.md docs/LOCALIZATION.md >/dev/null
then
  printf 'Removed online-service wiring, settings, credentials, or strings are still present.\n' >&2
  exit 1
fi

if rg -n 'https://(lrclib\.net/api|ws\.audioscrobbler\.com/2\.0|www\.last\.fm/api|musicbrainz\.org/ws/2|coverartarchive\.org|www\.wikidata\.org/w/api\.php|upload\.wikimedia\.org/wikipedia/commons)' \
  Application Managers Views Core Utilities Models Configuration Resources/Localizable.xcstrings PetrichorApp.swift >/dev/null
then
  printf 'Removed online-service endpoint is still referenced by runtime code.\n' >&2
  exit 1
fi

printf 'Online music services removed\n'
