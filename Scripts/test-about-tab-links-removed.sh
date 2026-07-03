#!/usr/bin/env bash
set -euo pipefail

about_view="Views/Settings/AboutTabView.swift"

if rg -n 'isAcknowledgementsExpanded|acknowledgementsSection|acknowledgementItem|title: "Acknowledgements"|title: "Website"|title: "Help"|title: "License"|About\.appWiki|About\.appAcknowledgements|logo-musicbrainz|logo-tmdb|logo-wikidata|logo-lastfm' "$about_view" >/dev/null; then
    printf 'About tab still exposes website/help/license/acknowledgements links.\n' >&2
    rg -n 'isAcknowledgementsExpanded|acknowledgementsSection|acknowledgementItem|title: "Acknowledgements"|title: "Website"|title: "Help"|title: "License"|About\.appWiki|About\.appAcknowledgements|logo-musicbrainz|logo-tmdb|logo-wikidata|logo-lastfm' "$about_view" >&2
    exit 1
fi

printf 'About tab external links removed\n'
