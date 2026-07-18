# ID3 Selective Metadata Writing Design

## Problem

The metadata editor currently writes every supported format through
`SFBAudioEngine.AudioMetadata`. For ID3-backed MPEG, WAVE, AIFF, DSF, DSDIFF,
and TrueAudio files—and FLAC files carrying a legacy ID3v2 tag—this can turn a
dirty-field patch into a whole-tag rewrite. ID3v2 data outside the editable
model—ratings, lyrics, artwork, owner data, identifiers, private frames,
unknown `TXXX` frames, and repeated values—can consequently be dropped or
normalized even when the user did not edit it.

The writable state is also inferred from the filename extension. A non-MP3
file renamed to `.mp3` can therefore be presented as writable before a real
container check is performed.

## Goals

- Write verified ID3v2 carriers by changing only the frame IDs represented by
  dirty patch fields.
- Preserve all frame IDs outside the dirty patch, including their order,
  multiplicity, and payloads.
- Preserve the existing SFBAudioEngine write path only for formats that do not
  expose an unsafe ID3v2 whole-tag rewrite.
- Continue reopening through SFBAudioEngine after every write and verify all
  dirty fields.
- Detect actual container content before choosing a writer, independent of the
  filename extension.
- Preserve `TDRC` text exactly for both `YYYY` and `YYYY-MM-DD`.
- Represent compilation false by removing `TCMP`, never by writing `0`.

## Architecture

The app target gains a direct Swift Package product dependency on CXXTagLib
2.3.0's `taglib` product. This package is already resolved transitively in the
local build graph; the direct declaration gives the app's Objective-C++ source
explicit compile-time access to TagLib APIs and adds no runtime network
service. A small Objective-C++ implementation exposes a Foundation-free C ABI
through the app's bridging header. Swift owns patch translation and error
mapping; Objective-C++ owns concrete-container probing and ID3v2 frame
mutation.

The C ABI accepts an array of operations. An unchanged Swift patch field emits
no operation, so it cannot reach the frame mutator. Set operations carry UTF-8
text; remove operations carry no value.

```c
typedef enum PTID3MetadataField {
    PTID3MetadataFieldTitle,
    PTID3MetadataFieldArtist,
    PTID3MetadataFieldAlbum,
    PTID3MetadataFieldAlbumArtist,
    PTID3MetadataFieldComposer,
    PTID3MetadataFieldGenre,
    PTID3MetadataFieldReleaseDate,
    PTID3MetadataFieldTrackNumber,
    PTID3MetadataFieldTrackTotal,
    PTID3MetadataFieldDiscNumber,
    PTID3MetadataFieldDiscTotal,
    PTID3MetadataFieldBPM,
    PTID3MetadataFieldCompilation,
    PTID3MetadataFieldComment
} PTID3MetadataField;

typedef enum PTID3PatchAction {
    PTID3PatchActionSet = 1,
    PTID3PatchActionRemove = 2
} PTID3PatchAction;
```

The bridge exposes:

- `PTID3ProbeContainerAtPath`, which probes actual MPEG Layer III, RIFF WAVE,
  AIFF, and TrueAudio content and distinguishes unsafe unverified ID3 carriers.
- `PTID3WriteMetadataAtPath`, which repeats the probe, obtains the concrete
  container's `ID3v2::Tag`, applies only supplied operations, and calls the
  matching format-specific save API.

The first safe implementation supports MPEG, WAVE, AIFF, and TrueAudio
selectively. DSF and DSDIFF are removed from the writable allowlist until
their format-specific bridge has a real-file regression fixture. FLAC with an
existing ID3v2 tag is reported as an unsafe ID3 carrier and made read-only;
plain FLAC continues to use its native Xiph/FLAC SFB path.

## Frame Mapping and Mutation

Dirty text fields remove all frames for their mapped ID and optionally add one
UTF-8 text frame:

| Field | Frame |
| --- | --- |
| title | `TIT2` |
| artist | `TPE1` |
| album | `TALB` |
| album artist | `TPE2` |
| composer | `TCOM` |
| genre | `TCON` |
| release date | `TDRC` |
| BPM | `TBPM` |

Track number/total and disc number/total are component edits of `TRCK` and
`TPOS`. The bridge first parses the current `number/total` text, applies only
the supplied component operations, then replaces that frame ID once. A
remaining total without a number is serialized as `/total`.

Compilation true replaces `TCMP` with one value of `1`. Compilation false or
remove deletes `TCMP`. Comment edits replace `COMM` frames with zero or one
canonical empty-description UTF-8 comment. This is intentional because `COMM`
is the corresponding editable frame family; untouched comments are never
visited.

Each format-specific save preserves the existing ID3v2 version where the API
allows selecting it. MPEG writes ID3v2 only, strips nothing, and does not
duplicate tags. Frames with all other IDs stay in TagLib's existing frame list
and are not recreated.

## Service Routing

For every allowlisted target:

1. File existence and filesystem writability are checked.
2. The bridge probes actual content.
3. Verified MPEG, WAVE, AIFF, and TrueAudio always use the selective bridge,
   even when the allowlisted extension is wrong.
4. An `.mp3` extension whose content fails the MPEG probe is rejected.
5. Any detected unverified ID3 carrier is read-only.
6. Remaining allowlisted native-tag content uses SFBAudioEngine.

This ordering prevents a real MPEG file with the wrong allowlisted extension
from falling back to whole-ID3 writing. All successful writes then reopen the
file with SFBAudioEngine and run `patch.mismatchedFields(in:)`.

## Testing

A focused shell test creates real temporary MP3, WAVE, AIFF, and TrueAudio
files with `ffmpeg`, compiles a TagLib-backed Objective-C++ harness, seeds
editable and advanced frames in each carrier, calls the production bridge,
and reopens with TagLib.

The fixture includes repeated `POPM`, `USLT`, and `APIC` frames plus unknown
`TXXX`, `PRIV`, and `UFID` frames. It compares serialized advanced-frame bytes
before and after an unrelated edit, then verifies:

- exact `YYYY-MM-DD` and `YYYY` `TDRC` round trips;
- false removes `TCMP`;
- true writes exactly one `TCMP` value of `1`;
- only explicitly dirty editable frame families change.

The existing source-level file-service test additionally requires bridge
routing for all verified carriers, content-based writer selection, safe
rejection of unverified carriers, the retained native non-ID3 SFBAudioEngine
path, and reopen verification. Probe coverage includes a real MPEG under a
non-MP3 allowlisted extension, a FLAC renamed `.mp3`, and a Shorten-signature
fixture renamed `.mp3`.
