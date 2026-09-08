# Recording Trash

The modern library can preserve a SavedClips or SentryClips event in private Trash,
restore it, or permanently delete its preserved copy. The retention period is 30
days from the successful copy, using verified UTC time on the Pi.

## Storage semantics

`/mutable/TeslaCam` is an index of links into read-only snapshots. Moving those links
would not preserve a recording when snapshot cleanup releases its backing data.
Trash therefore copies every supported original camera and metadata file into
`/mutable/teslausb-recording-trash/objects/<random object>/` before publishing its
tombstone. This private directory must stay outside every nginx static alias.

Moving to Trash does **not** free the original snapshot or car disk allocation. It
uses additional storage for the preserved copy. Permanent deletion frees only the
private copy; original snapshots, car recordings and archive copies are unchanged.
Normal snapshot cleanup controls the lifetime of the original snapshot data.
The UI must state these semantics at deletion and in the storage overview.

Restoring exposes the owned copy through authenticated API routes and the modern
library's restored overlay. It does not write back to the car or snapshot index.
Restored copies remain preserved until explicitly moved to Trash again; they do
not expire automatically. Moving a restored copy to Trash reuses the copy and
starts another verified 30-day interval even if the source snapshot no longer exists.

Tombstones are permanent, snapshot-independent identities: SHA-256 of the exact
category/event path. They survive permanent deletion. The API also returns
`hidden_media`, the timestamp/camera filenames that must be suppressed across
other category aliases, including RecentClips. Generic names such as `event.json`
are not used for cross-event suppression. Restored overlays take priority over all
original aliases. The modern client must fail closed if it cannot load Trash
state, rather than display a list which may resurrect deleted recordings.
Legacy directory listings are not rewritten by this module.

## API

Every mutation uses POST, JSON, same-origin credentials, and the existing
`X-TeslaUSB-Request: 1` mutation guard. Paths and commands are never taken from JSON.

| Route | Input | Result |
| --- | --- | --- |
| `GET /api/v1/trash` | None | Current state below |
| `POST /api/v1/trash/move` | `{"event":"SentryClips/2026-09-08_12-30-00"}` | Copies one event, then returns current state |
| `POST /api/v1/trash/restore` | `{"ids":["<64-character id>"]}` | Restores 1–20 items, then returns current state |
| `POST /api/v1/trash/delete` | `{"ids":["<64-character id>"]}` | Deletes 1–20 private copies, then returns current state |
| `GET /api/v1/trash/media?id=...&file=...` | One exact manifest-owned file | Browser-compatible MP4 playback, metadata JSON, or image; single HTTP byte ranges supported |
| `GET /api/v1/trash/download?id=...&camera=all` | Preserved item and camera, optional `info=1` | Original download/ZIP via `recording-media.sh`; no source fallback |

The separate recording media helper also serves restored originals through its
ordinary `recordings/download?event=...&camera=...` contract.

The existing `cttseraser.cpp` FUSE view changes the first parsed MP4 `ctts` atom's
four-character type to `@@@@` during playback reads for Chromium compatibility.
Preserved originals do not pass through that view, so `trash/media` performs the
same nonmutating, length-preserving adjustment while streaming. It walks only atom
headers with limits on count, nesting, and scan time; media payloads are skipped,
never searched for incidental `ctts` text. The patch also covers partial HTTP
ranges crossing those four bytes. Malformed or excessively complex metadata fails
before response headers with an instruction to download the original. Private
files and both original download routes remain byte-for-byte unchanged.

Current state contains `ok`, `retention_days`, `clock.trusted`, `items` (trashed),
`restored`, `tombstones`, `hidden_media`, `retained_bytes`, `free_bytes`,
`reserve_bytes`, and a storage-semantics note. Each public item contains `id`,
`event`, `category`, `event_time`, `deleted_at`, `expires_at`, `bytes`, and
`files: [{name,bytes,camera,media_url}]`. Timestamps are UTC ISO strings. Camera is
null for metadata and thumbnails. Private filesystem paths are never returned.

An interrupted HTTP response can follow a committed mutation. The client must
refresh state and show the actual outcome rather than claim a rollback. Bulk moves
are sequential one-event operations; report per-event successes and failures.

## Safety and limits

- The storage root must already exist, be owned by the CGI user, and have mode
  `0700`. Each directory component is pinned with `openat` and `O_NOFOLLOW`.
- Only exact Saved/Sentry event folders, recognized camera MP4 filenames, and
  `event.json`/supported thumbnails are copied. Recent-only events and all
  EncryptedClips paths are excluded. Unknown event contents fail without deletion.
- Index aliases must point to the same event and filename in an exact numbered
  snapshot. The publisher's `/backingfiles/snapshots/snap-######/mnt/...` spelling is
  translated only to its canonical `/tmp/snapshots/snap-######/...` path. Arbitrary
  symlink resolution, parent escapes, and writable source mounts are refused.
- A shared lock on the existing snapshots directory prevents snapshot replacement
  or release during copying. An exclusive nonblocking private lock serializes
  Trash reads/mutations. Busy operations return a retryable conflict.
- All copied files and their directory are fsynced before an atomic manifest
  replacement. Publication failures retain durable data if the commit outcome is
  uncertain. A later cleanup can remove unreferenced staging objects.
- Permanently deleted state is persisted before unlinking owned files. Cleanup is
  flat and descriptor-relative; it never recursively follows a directory or link.
  A crash retries remaining private object removal without resurrecting aliases.
- Copy capacity requires event bytes plus a reserve of at least 256 MiB or 5% of
  the storage filesystem, whichever is greater. Supported events are bounded to
  16 GiB and 4,096 files. Source size/inode/mtime are checked around the copy.
- Copying is synchronous with a 50-second loop budget and 58-second process alarm.
  A very large event or slow card can time out. The UI reports that outcome and
  refreshes; no car/snapshot files are modified. An asynchronous copy queue is a
  future enhancement, not implemented here. Concurrent video streams may make a
  copy slower; pause playback and retry when appropriate.
- Verified time comes only from the existing fixed `maintenance-health` privilege
  boundary. Evidence must be synchronized, recent, and consistent with elapsed
  monotonic time. A guessed wall clock, offline fallback, stale evidence or clock
  step blocks new moves and pauses automatic expiry. Restore and explicit permanent
  delete remain available. No files are auto-deleted merely because a stored date
  looks old while clock trust is missing.

## Integration

1. Install `recording-trash.py` and its shell wrapper as root-owned application
   files. Keep `maintenance.py` available beside them for the fixed health query.
2. Provision `/mutable/teslausb-recording-trash` as a real directory owned by the
   CGI account with mode `0700`. Do not weaken `/mutable` or snapshots permissions.
3. Route exact Trash status/media/mutation routes to `recording-trash.sh`. Route
   `trash/download` to `recording-media.sh` first; it shares camera/ZIP handling.
   Add the mutation routes to the API dispatcher's central POST guard as well.
4. Include `modern/trash.css` and import `mountTrash` from `modern/trash.js`.
   `mountTrash(container,{api,onNotice,onLibraryChanged})` returns
   `{refresh(),suspend(),destroy()}`. `api` accepts a URL and fetch-style options and returns
   decoded JSON. `onLibraryChanged(state)` reconciles the main clip list.
   Previews release all media sources when the browser document becomes hidden,
   when the page unloads, or when the mount section gains `hidden`/`aria-hidden`.
   Page routers can also call `suspend()` explicitly; previews restart only through
   a user action. `destroy()` removes the associated observers and listeners.
5. Install `run/recording-trash-cleanup.sh` as `/root/bin/recording-trash-cleanup.sh`
   if that is the usual script destination, but a web-user service cannot traverse
   `/root`. Prefer systemd `ExecStart=/usr/bin/python3 -I
   /var/www/html/cgi-bin/recording-trash.py cleanup`, with `User=www-data` (or the
   actual CGI user). The installed timer runs hourly with up to five minutes of
   randomized delay and `Persistent=true`. The
   helper does not depend on an open browser. Expiry runs on the first eligible
   timer tick after 30 days; missing verified time defers it.
   The cleanup process emits a compact JSON journal record and exits nonzero on
   storage/verification errors, so systemd can distinguish failure from safe clock
   deferral. Browser CGI endpoints retain normal HTTP JSON responses.
6. The timer needs the existing tightly scoped sudo permission for
   `maintenance-health`. Do not add broad filesystem, shell or root write access.
7. After installation, verify the service user can take a shared snapshot directory
   lock, read the snapshots, write its private store, and query verified clock
   evidence. Missing access is a visible failure, not a reason to bypass checks.

## Verification

Run `python3 -m unittest discover -s tests -p test_recording_trash.py -v`.
Pure contract tests run on Windows and Linux. The lifecycle suite deliberately
requires POSIX `openat`, `flock`, `O_NOFOLLOW`, and filesystem mount flags. It tests
copy-before-hide, recovery after source removal, re-trash, expiry, untrusted time,
read/write failures, source alias escape, mutable mounts, lock conflicts,
symlink/hardlink attacks, corruption, and permanent tombstone retention. It mocks
only the read-only mount flag because temporary test fixtures are ordinary files.

The Windows authoring environment cannot execute those POSIX lifecycle tests.
Passing only the portable subset is not Linux/device validation. Run the complete
suite in Linux CI before deployment, then verify actual read-only FUSE mounting,
CGI permissions, timer behavior and capacity reporting on a nonproduction fixture.
