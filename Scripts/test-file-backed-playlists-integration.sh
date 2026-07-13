#!/usr/bin/env bash
set -euo pipefail

if ! rg -n "struct PlaylistFileBacking" Models/Core/Playlist.swift >/dev/null; then
    printf 'PlaylistFileBacking is missing from Playlist model.\n' >&2
    exit 1
fi

if ! rg -n "fileBacking: PlaylistFileBacking\\?" Models/Core/Playlist.swift >/dev/null; then
    printf 'Playlist.fileBacking is missing.\n' >&2
    exit 1
fi

if rg -n "DefaultPlaylists\\.favorites" Models/Core/Playlist.swift Managers/Database/DMSetup.swift >/dev/null; then
    printf 'Built-in Favorites playlist is still seeded by defaults or setup.\n' >&2
    exit 1
fi

if ! rg -n "final class PlaylistFileStore" Managers/Playlist/PlaylistFileStore.swift >/dev/null; then
    printf 'PlaylistFileStore is missing.\n' >&2
    exit 1
fi

if ! rg -n "loadPlaylists\\(from folders: \\[Folder\\], databaseManager: DatabaseManager\\)" Managers/Playlist/PlaylistFileStore.swift >/dev/null; then
    printf 'PlaylistFileStore.loadPlaylists signature is missing.\n' >&2
    exit 1
fi

if ! rg -n "PlaylistFileStore" Managers/Playlist/PlaylistManager.swift >/dev/null; then
    printf 'PlaylistManager does not use PlaylistFileStore.\n' >&2
    exit 1
fi

if rg -n "let savedRegularPlaylists = savedPlaylists\\.filter" Managers/Playlist/PlaylistManager.swift >/dev/null; then
    printf 'PlaylistManager still loads regular playlists from the database.\n' >&2
    exit 1
fi

if rg -n "savePlaylistAsync\\(newPlaylist\\)|appendTracksToPlaylist|removeTracksFromPlaylist\\(playlistId:|setPlaylistTrackOrder" Managers/Playlist/PMRegularPlaylists.swift >/dev/null; then
    printf 'Regular playlist mutations still call database playlist-track APIs.\n' >&2
    exit 1
fi

if ! rg -n "playlistFileStore\\.write|playlistFileStore\\.createPlaylist|playlistFileStore\\.rename|playlistFileStore\\.delete" Managers/Playlist/PMRegularPlaylists.swift >/dev/null; then
    printf 'Regular playlist mutations are not wired to PlaylistFileStore.\n' >&2
    exit 1
fi

if ! rg -n "TrackTrashFallback|moveItemToLocalTrashFallback" Managers/Playlist/PlaylistFileStore.swift >/dev/null; then
    printf 'PlaylistFileStore must fall back to the user Trash when a source volume has no Trash.\n' >&2
    exit 1
fi

if rg -n "Import Playlists|Export Playlists|importPlaylistsMenuItem|exportPlaylistsMenuItem|showingExportPlaylistSheet|ExportPlaylistsSheet|\\.importPlaylists|\\.exportPlaylists" PetrichorApp.swift Views Managers/Playlist >/dev/null; then
    printf 'Import/export playlist UI or notifications are still present.\n' >&2
    exit 1
fi

if rg -n "func importPlaylists\\(|func exportPlaylists\\(|BulkImportResult|BulkExportResult" Managers/Playlist >/dev/null; then
    printf 'Playlist import/export manager APIs are still present.\n' >&2
    exit 1
fi

if rg -n "DefaultPlaylists\\.favorites" Managers/Playlist/PMTrackUpdate.swift >/dev/null; then
    printf 'Favorites smart playlist runtime hook still exists.\n' >&2
    exit 1
fi

if ! rg -n "DefaultPlaylists\\.recentlyPlayed" Managers/Database/DMSetup.swift >/dev/null; then
    printf 'Recently played default playlist is not pinned or seeded in setup.\n' >&2
    exit 1
fi

printf 'File-backed playlist integration checks passed\n'
