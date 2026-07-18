# Track Metadata Playback Write Suspension Design

## Goal

Keep the audio engine away from a current track for the complete metadata-write
window, while preserving transport actions that arrive after playback was
suspended.

## Confirmed Behavior

- Suspension starts before `prepareCurrentTrackForMetadataEdit(_:)` stops the
  engine and remains active until the matching restoration or cleanup call
  reaches a terminal path.
- With no user action, a playing track resumes, a paused track remains paused,
  and an idle selected track remains idle at the saved position.
- Toggle, stop, and seek during the write window update the final playback
  intent or position without reopening the edited file.
- Explicit stop wins over the pre-write snapshot and must not auto-play when
  the window closes.
- A request to play the same edited track is deferred until the window closes.
- Next, previous, or an explicit request for another track supersedes the
  original restoration and may safely play that different file immediately.
  The new queue index and current-track choice remain authoritative.
- A stale restoration callback never rewinds a newer queue or current-track
  choice.
- Cancellation and every write, verification, or reindex error consume the
  matching suspension exactly once through the same restoration completion
  contract as the success path.
- The internal stop performed by preparation is not interpreted as a user stop.
- Mixed-field setter semantics, database behavior, tag models, and playback
  backends remain unchanged.

## Architecture

`PlaybackManager` remains the sole transport authority. It owns one
generation-scoped metadata-edit suspension. The snapshot returned to the editor
contains the generation, so a later restore can consume only the session that
created it.

The session's value semantics live in a Foundation-only reducer under
`Core/Playback`. It records:

- the edited track identity;
- the generation;
- the desired post-write mode (`playing`, `paused`, idle-selected, or explicit
  stop);
- the latest desired position;
- whether the original queue index may still be restored; and
- whether a different-track request superseded the original restoration.

This reducer is independently executable from a shell regression harness.
`PlaybackManager` supplies engine effects only after applying the reducer's
decision.

## Transport Flow

Preparation snapshots the original state, creates the suspension, and only then
stops the engine directly. It does not call the public `stop()` transport
method.

While the matching suspension is active and not superseded:

- toggle mutates the desired mode and returns before any engine command;
- stop records explicit stop and returns before clearing or reopening the
  engine;
- seek records a sanitized position and returns before calling engine seek;
- same-track play records `playing`, invalidates stale asynchronous playback
  loads, and defers engine open; and
- different-track play marks the suspension superseded and continues through
  the normal playback path.

Once superseded, toggle, stop, and seek apply normally to the newly selected
different track. If the edited track is explicitly selected again before the
write ends, that latest request becomes deferred and the different playback
request is invalidated.

## Restoration Contract

`restoreCurrentTrackAfterMetadataEdit` always resolves its supplied completion
once:

- nil, stale-generation, and superseded snapshots complete successfully
  without mutating playback or queue state;
- explicit stop consumes the session, applies normal stopped state, and
  completes successfully;
- idle-selected restoration reinstates updated metadata and the latest
  position without opening the engine;
- playing or paused restoration reinstates updated metadata and the latest
  position, then uses the existing entry- and generation-guarded asynchronous
  restore operation.

The session is removed before terminal effects are applied, preventing
restoration's own engine actions from being mistaken for user actions.

## Testing

The focused playback script compiles and runs the pure reducer to cover:

- unchanged playing, paused, and idle-selected state;
- toggle and seek intent updates;
- explicit stop;
- same-track defer without queue rewind;
- different-track supersession;
- selecting the edited track again after supersession; and
- standardized URL fallback when database IDs are absent.

Structural checks ensure `PlaybackManager` intercepts each transport before the
corresponding engine effect and consumes a generation-matched session before
restoration mutates queue or current track.

The editor orchestration harness verifies that success, write/reindex failure,
and cancellation each prepare and restore exactly one generation-scoped token.
All playback regression scripts and an unsigned Debug build are required before
completion.
