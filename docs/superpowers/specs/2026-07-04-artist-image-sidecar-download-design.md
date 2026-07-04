# Artist Image Sidecar Download Design

## Goal

Add an optional online artist image downloader without reintroducing database-stored artist artwork.
Downloaded images are written as sidecar files in song directories using the artist name as the filename.

## User Control

The setting lives next to the existing online lyrics setting in `Settings > Integrations > Lyrics & Metadata`.
It uses a new `artistImageDownloadEnabled` preference and is disabled by default.

## Download Source

Image discovery follows the upstream Petrichor approach for artist images:

1. Search MusicBrainz for the artist.
2. Read the MusicBrainz Wikidata relationship.
3. Resolve Wikidata P18 image claims to a Wikimedia Commons thumbnail URL.
4. Download and write the image to disk.

TMDB and artist bio fetching are intentionally out of scope for this change.

## Storage

Images are stored outside SQLite and outside the artwork cache. For each track directory where the artist appears,
Petrichor writes `<artist name>.jpg`, after sanitizing path separators and reserved filename characters.
Existing artist image files are not overwritten.

## Triggering

When the setting is enabled, Petrichor starts a background pass after the library is loaded. This covers initial scan,
manual library refresh, and single-folder refresh because they all end by reloading the library.
Turning the setting on also starts a background pass immediately.

## Non-Goals

This does not restore the removed artist artwork database feature and does not make artist pages use remote images directly.
The downloaded files are normal sidecar images that can be managed by the user.
