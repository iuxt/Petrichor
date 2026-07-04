#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

store="Core/ArtistImageStore.swift"
manager="Managers/ArtistImageDownloadManager.swift"
settings="Views/Settings/IntegrationsTabView.swift"
grid="Views/Components/EntityGridView.swift"
detail="Views/Home/EntityDetailView.swift"
strings="Resources/Localizable.xcstrings"

if [[ ! -f "$store" ]]; then
  echo "Missing ArtistImageStore." >&2
  exit 1
fi

for pattern in \
  "enum ArtistImageStore" \
  "artistImagesDirectoryName = \"artist images\"" \
  "imageDirectory\\(forMusicRoot" \
  "preferredImageURL\\(artistName:musicRoot:" \
  "existingImageURL\\(artistName:musicRoot:" \
  "imageData\\(for artistName:" \
  "groupedArtistsByMusicRoot\\(from tracks:" \
  "musicRoot\\(containing url:" \
  "writeImage\\(_ data:" \
  "AlbumArtFormat\\.supportedExtensions"; do
  if ! rg -n "$pattern" "$store" >/dev/null; then
    echo "ArtistImageStore missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "DatabaseManager|updateArtist|artwork_data|artistArtwork|artist\\.artworkData" "$store" >/dev/null; then
  echo "ArtistImageStore must not read or write artist artwork through the database." >&2
  exit 1
fi

for pattern in \
  "final class ArtistImageDownloadManager" \
  "static let shared = ArtistImageDownloadManager" \
  "artistImageDownloadEnabled" \
  "https://musicbrainz.org/ws/2/artist/" \
  "https://www.wikidata.org/w/api.php" \
  "commonsThumbUrl" \
  "libraryManager\\.databaseManager\\.getAllFolders\\(\\)" \
  "ArtistImageStore\\.groupedArtistsByMusicRoot" \
  "ArtistImageStore\\.existingImageURL" \
  "ArtistImageStore\\.writeImage" \
  "NotificationCenter\\.default\\.post\\(name: \\.artistImagesDidChange" \
  "UserDefaults\\.standard\\.bool\\(forKey: Self\\.artistImageDownloadEnabledKey\\)"; do
  if ! rg -n "$pattern" "$manager" >/dev/null; then
    echo "ArtistImageDownloadManager missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "deletingLastPathComponent\\(\\)|appendingPathComponent\\(filename\\)\\.appendingPathExtension\\(\"jpg\"\\)|sanitizedArtistFilename\\(" "$manager" >/dev/null; then
  echo "Artist image downloader still writes images beside individual songs." >&2
  exit 1
fi

if rg -n "updateArtist|artwork_data|artistArtwork|artist\\.artworkData" "$manager" >/dev/null; then
  echo "Artist image downloader must not write artist artwork to the database." >&2
  exit 1
fi

if ! rg -n "@AppStorage\\(\"artistImageDownloadEnabled\"\\)" "$settings" >/dev/null; then
  echo "Missing artist image download setting." >&2
  exit 1
fi

if ! rg -n "Download artist images to music folders|ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages" "$settings" >/dev/null; then
  echo "Settings UI does not expose or trigger artist image downloads." >&2
  exit 1
fi

if rg -n "Download artist images to song folders|next to songs" "$settings" >/dev/null; then
  echo "Settings UI still describes song-folder artist image storage." >&2
  exit 1
fi

if ! rg -n "ArtistImageStore\\.imageData\\(for: artist(Name|\\.name)" "$grid" >/dev/null; then
  echo "Artist grid does not read file-backed artist images." >&2
  exit 1
fi

if ! rg -n "artistImageRefreshID|publisher\\(for: \\.artistImagesDidChange\\)" "$grid" >/dev/null; then
  echo "Artist grid does not refresh after artist image downloads change files." >&2
  exit 1
fi

if ! rg -n "artistImageData|loadArtistImage|ArtistImageStore\\.imageData\\(for: entity\\.name" "$detail" >/dev/null; then
  echo "Artist detail does not read file-backed artist images." >&2
  exit 1
fi

if ! rg -n "publisher\\(for: \\.artistImagesDidChange\\)" "$detail" >/dev/null; then
  echo "Artist detail does not refresh after artist image downloads change files." >&2
  exit 1
fi

if ! rg -n "artistImagesDidChange" Utilities/Constants.swift >/dev/null; then
  echo "Missing artist image change notification." >&2
  exit 1
fi

for pattern in \
  "\"Download artist images to music folders\"" \
  "\"下载艺人图片到音乐文件夹\"" \
  "\"artist images\"" \
  "\"艺人图片\""; do
  if ! rg -n "$pattern" "$strings" >/dev/null; then
    echo "Missing localized artist image setting pattern: $pattern" >&2
    exit 1
  fi
done

if ! rg -n "ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages\\(using: self\\)" \
  Managers/Library/LMLibrary.swift >/dev/null; then
  echo "Library load does not trigger artist image download pass." >&2
  exit 1
fi
