# Static Track File Details Design

## Goal

Make the File Details section in the track detail sidebar visually match the existing Details section and keep it visible at all times.

## Current Context

`TrackDetailView` renders the Details section with a static headline followed by a rounded `thinMaterial` metadata card. File Details currently uses a separate `FileDetailsSection` view with a chevron button, local expansion state, and an animated conditional card.

The file metadata itself is already complete and ordered correctly. This change is limited to its presentation.

## Recommended Approach

Reuse the existing `metadataSection(title:items:)` builder for both sections.

Move the file-details item construction into `TrackDetailView`, pass those items to `metadataSection` with the localized `File Details` title, and remove the dedicated collapsible `FileDetailsSection`.

Alternatives considered:

- Keep `FileDetailsSection` but make it static. This is a smaller-looking edit but preserves duplicate metadata layout code.
- Extract a new shared component. This would also remove duplication, but it broadens the refactor without adding value beyond the existing builder.

## UI Behavior

- File Details is always visible below Details.
- Its title uses the same headline styling as Details.
- Its values use the same label widths, typography, spacing, text selection behavior, padding, rounded corners, and `thinMaterial` background as Details.
- There is no chevron, button interaction, expansion state, conditional content, transition, or expansion animation.
- Existing file metadata fields, order, formatting, and localized strings remain unchanged.

## Data Flow and Error Handling

The existing `FullTrack` loading flow remains unchanged. Once a full track is available, the view derives track metadata and file metadata as two item arrays and renders both with the same section builder.

No new error paths are introduced. Existing optional file properties continue to be omitted when unavailable, while format and file path keep the File Details section nonempty.

## Testing and Verification

Add a focused source check that verifies:

- File Details is rendered through `metadataSection`.
- The obsolete collapsible view and expansion state are absent.

Run the focused check, the localization format-specifier check, and a Debug build of the Petrichor scheme when the local Xcode environment permits it.

## Out of Scope

- Changing metadata fields, ordering, formatting, or localization.
- Changing the track detail sidebar layout outside these two metadata sections.
- Changing artwork behavior, track loading, or database access.
