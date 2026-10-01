#!/usr/bin/env python3
"""Export TTML already cached by macOS Music.app; makes no network requests.

Usage:
  python3 Scripts/export-apple-music-ttml.py list
  python3 Scripts/export-apple-music-ttml.py save SONG_ID --output /path/to/song.ttml

Open a catalog song's lyrics in Music.app first so the response is cached.
The Music.app cache is private and may change with a macOS update.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET


MAX_RESPONSE_BYTES = 5_000_000
MAX_FALLBACK_FILES = 500
CACHE_NAME = re.compile(r"[0-9a-fA-F-]{36}\Z")
SONG_ID_IN_URL = re.compile(r"/songs/(\d+)/syllable-lyrics")


def cache_responses(root: Path):
    """Yield indexed responses newest first, then recent unindexed cache files."""
    data_dir = root / "fsCachedData"
    indexed_files = set()
    database = root / "Cache.db"
    if database.is_file():
        try:
            with sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True) as connection:
                rows = connection.execute(
                    "SELECT r.request_key, d.isDataOnFS, d.receiver_data "
                    "FROM cfurl_cache_response AS r "
                    "JOIN cfurl_cache_receiver_data AS d USING (entry_ID) "
                    "WHERE r.request_key LIKE '%syllable-lyrics%' "
                    "ORDER BY r.time_stamp DESC"
                )
                for request_key, is_file, payload in rows:
                    if is_file:
                        name = payload.decode("utf-8", "replace") if isinstance(payload, bytes) else payload
                        if not CACHE_NAME.fullmatch(name):
                            continue
                        path = data_dir / name
                        indexed_files.add(path)
                        try:
                            if path.stat().st_size <= MAX_RESPONSE_BYTES:
                                yield request_key, path.read_bytes()
                        except OSError:
                            continue
                    elif isinstance(payload, bytes) and len(payload) <= MAX_RESPONSE_BYTES:
                        yield request_key, payload
        except sqlite3.Error as error:
            print(f"Cache.db cannot be read ({error}); scanning recent cache files.", file=sys.stderr)

    try:
        recent = []
        for path in data_dir.iterdir():
            try:
                recent.append((path.stat().st_mtime, path))
            except OSError:
                continue
    except OSError:
        return
    for _, path in sorted(recent, reverse=True)[:MAX_FALLBACK_FILES]:
        if path in indexed_files or not CACHE_NAME.fullmatch(path.name):
            continue
        try:
            if path.is_file() and path.stat().st_size <= MAX_RESPONSE_BYTES:
                yield "", path.read_bytes()
        except OSError:
            continue


def localizations(attributes):
    value = attributes.get("ttmlLocalizations", attributes.get("ttml"))
    if isinstance(value, str):
        if value.lstrip().startswith("<"):
            return {"original": value}
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return {}
    if isinstance(value, dict):
        return {key: text for key, text in value.items() if isinstance(text, str) and text.lstrip().startswith("<")}
    return {}


def songs_in_response(request_key, response):
    try:
        items = json.loads(response).get("data", [])
    except (ValueError, UnicodeDecodeError, TypeError):
        return
    if not isinstance(items, list):
        return
    url_id = SONG_ID_IN_URL.search(request_key or "")
    for item in items:
        if not isinstance(item, dict):
            continue
        attributes = item.get("attributes") or {}
        relationships = item.get("relationships") or {}
        lyric_items = (relationships.get("syllable-lyrics") or {}).get("data") or []
        candidates = [entry.get("attributes") or {} for entry in lyric_items if isinstance(entry, dict)]
        candidates.append(attributes)  # Also accept a direct syllable-lyrics response.
        lyrics = next((found for candidate in candidates if (found := localizations(candidate))), None)
        if not lyrics:
            continue
        # A direct lyrics response can use a lyric-resource ID; its request URL
        # still carries the catalog song ID needed by the save command.
        song_id = str(
            url_id.group(1) if url_id and not attributes.get("name")
            else item.get("id") or (url_id.group(1) if url_id else "")
        )
        if not song_id:
            continue
        yield song_id, attributes.get("name", ""), attributes.get("artistName", ""), lyrics


def cached_songs(root):
    seen = set()
    for request_key, response in cache_responses(root):
        for song in songs_in_response(request_key, response):
            if song[0] not in seen:
                seen.add(song[0])
                yield song


def select_ttml(lyrics, requested_locale):
    if requested_locale:
        for locale, ttml in lyrics.items():
            if locale.casefold() == requested_locale.casefold():
                return locale, ttml
        raise ValueError(f"Locale {requested_locale!r} is unavailable; choose from: {', '.join(lyrics)}")
    if "original" in lyrics:
        return "original", lyrics["original"]
    locale = sorted(lyrics)[0]
    return locale, lyrics[locale]


def validate_ttml(ttml):
    try:
        root = ET.fromstring(ttml)
    except ET.ParseError as error:
        raise ValueError(f"Cached TTML is invalid XML: {error}") from error
    if root.tag.rsplit("}", 1)[-1] != "tt" or not any(
        node.tag.rsplit("}", 1)[-1] == "p" for node in root.iter()
    ):
        raise ValueError("Cached response does not contain TTML lyric lines")


def save_exclusively(path, ttml):
    if path.suffix.lower() != ".ttml":
        raise ValueError("Output file must have a .ttml extension")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o644)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as output:
            output.write(ttml)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache-dir", type=Path, default=Path.home() / "Library/Caches/com.apple.Music",
                        help=argparse.SUPPRESS)
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("list", help="List songs with TTML in the Music.app cache")
    save = actions.add_parser("save", help="Save one cached song as a TTML file")
    save.add_argument("song_id", help="Apple Music song ID shown by list")
    save.add_argument("--output", required=True, type=Path, help="Destination .ttml file; must not exist")
    save.add_argument("--locale", help="Choose a locale shown by list (default: original/first)")
    args = parser.parse_args()

    if not args.cache_dir.is_dir():
        parser.exit(1, f"Music.app cache not found: {args.cache_dir}\n")
    try:
        if args.action == "list":
            count = 0
            for song_id, title, artist, lyrics in cached_songs(args.cache_dir):
                print(f"{song_id}\t{title or '(untitled)'}\t{artist}\t[{', '.join(lyrics)}]")
                count += 1
            if not count:
                print("No cached TTML found. Play a catalog song and open its lyrics in Music.app.", file=sys.stderr)
                return 1
            return 0

        for song_id, title, artist, lyrics in cached_songs(args.cache_dir):
            if song_id == args.song_id:
                locale, ttml = select_ttml(lyrics, args.locale)
                validate_ttml(ttml)
                save_exclusively(args.output, ttml)
                print(f"Saved {title or song_id} — {artist} ({locale}) to {args.output}")
                return 0
        print(f"Song {args.song_id} has no TTML in the Music.app cache.", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
