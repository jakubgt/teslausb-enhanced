# Modern TeslaUSB interface

The normal `/` landing page now opens the built-in modern interface. The same
interface is available at `/modern/`. **Classic UI** links remain available on
desktop and phones at `/index.html?ui=legacy`. Existing custom Vue configuration
and Classic files remain installed. No BLE controls are added to the modern UI.

## Recordings

The first screen opens the newest available recording in **Single camera** mode.
Use **All cameras** for synchronized angles. This is the latest **completed
snapshot footage**, not a live connection to Tesla cameras. The screen reports
the newest listed recording, last verified completed snapshot, and last library
refresh separately; USB connection alone does not prove active recording.

Six exterior camera files are supported: Front, Rear, Left repeater, Right
repeater, Left pillar, and Right pillar. The sample includes all six. Real clips
show the cameras actually recorded, so older four-camera footage remains usable;
a camera missing from a particular segment is identified in the All cameras view.

The date filter defaults to the newest date with visible clips, including restored
copies and skipping dates emptied by Trash. Categories, search, selection, and
pagination operate within that day. Refresh retains the current recording,
camera, timeline position, layout, quality, speed, and playback intention when
the event is still available. Leaving or hiding the viewer releases video
sources. A failed refresh keeps the previous list and labels it stale.

Recent daily footage is browsable by recorded hour, initially the latest hour
with clips. The hour menu lists only populated hours with clip counts, plus
**All hours**. Each synchronized minute is one clip regardless of camera count.
Every category shows at most 20 clips/events per page: 60 Recent minute clips
produce three pages; sparse hours produce fewer. Saved and Sentry events keep
their complete segment grouping and are not split by the hour filter.
Previous/Next and a page selector replace an ever-growing grid. Browsing pages,
hours, and search results does not reload the day or interrupt the active video.
Refresh keeps the selected hour/page when still available; changed dates reset
to the latest populated hour. Bulk selection applies only to the visible page
and clears when changing pages or filters.

Playback starts with Low preview checks. Low is an actual smaller H.264 encode,
prepared on demand one segment at a time. Availability, preparation, failure,
and retry are explicit. **Play original** switches to High; original files are
never quietly represented as Low. Restored copies currently support High only.
See [media constraints and APIs](ModernMedia.md) for the encoder's resource limits.

The viewer supports fullscreen, -10/+10 seconds, playback speed, camera selection,
an approximate segment timeline, metadata, and a Sentry event marker when its
timestamp matches an available segment. File timestamps have no timezone, so
unmatched metadata never produces a guessed jump. Map data loads from
OpenStreetMap only after a user clicks **Load location map**.

**Download camera** and **Download all cameras** prepare original files and show
their combined source size. A single file downloads as MP4; multiple segments or
cameras download as an uncompressed ZIP containing separate originals. Preparation
has cancellation and failure/retry feedback. Clicking Save hands the transfer to
the browser's Downloads, which owns transfer progress and cancellation. The page
does not claim an unverified download completion or buffer a large ZIP in RAM.

## Trash

Saved and Sentry events can be selected individually or together. Moving an event
first preserves its camera and metadata files in private storage, then hides its
snapshot aliases in the modern library. Undo and Restore expose this owned copy.
Trash expires after 30 days on the next hourly cleanup tick, provided the device
has verified time; explicit permanent deletion is also available with confirmation.

**Trash uses additional storage.** The snapshot index is read-only. Deleting a
private recovery copy does not erase car recordings, archives, or original
snapshots; normal snapshot cleanup still controls those originals. Classic
directory listings retain their historical view. Restored copies stay preserved
until explicitly trashed again. Large events on slow storage may exceed the copy
deadline and fail with a visible retry message. See [storage and recovery
semantics](RecordingTrash.md) for exact behavior and limits.

## Device and Files

Device has Overview, Archive, Logs, and Tools panels. Archive includes Sync now,
pending files/bytes, progress, errors, and a persistent last successful archive
timestamp. Tools include a cancellable network speed test, Power controls, USB
connect/disconnect, USB repair, and SSH help. Playback pauses for the speed test.
Storage, temperature, power/throttling, and encrypted-recording alerts are retained.

The Power card groups Reboot and Shut down TeslaUSB. Both require confirmation
and pause playback. Shutdown takes the Pi offline; starting it again requires
disconnecting and reconnecting power after it finishes shutting down. The API
acknowledges that the action was queued, not that the device completed it. Device
polling and action buttons pause until a manual status check receives a response;
the pending state survives cached-page restoration and keeps navigation on Device.
Failed or lost power requests are never retried automatically. A successful status
check confirms connectivity only. The local preview simulates both actions and
never issues a host power command.

Logs separate diagnostics, archive, setup, and maintenance. Each supports refresh,
search, line wrapping, full captured text, and download. Bounded log tails clearly
report truncation; the interface never calls a captured tail the complete original
log. A combined text bundle is available. Fresh diagnostic generation is explicit.

Files appears only when Music, LightShow, or Boombox is configured. It reuses the
existing file browser for upload, folders, rename, playback, and downloads, with
media cleanup when navigating away. The modern UI has light, dark, and automatic
appearance and adapts to phone widths without horizontal scrolling.

## Setup and validation

Normal web setup installs modern assets, exact API routes, optional ffmpeg/ffprobe,
private www-data-owned directories (mode 0700), and the hourly Trash timer. The
helpers use the existing same-origin/host/authentication boundary; no broad sudo
filesystem capability or live camera mount is added. Python helper files cannot
be downloaded directly through nginx.

Linux CI runs ShellCheck, Python lifecycle/security and real ffmpeg tests, nginx
and sudoers validation, shell integration checks, and browser tests with generated
fictional footage. Browser tests run actual production modules against a
localhost-only fixture server; they do not contact a Pi or edit real recordings.

For a local interactive preview, install Playwright in a separate runtime, set
`NODE_PATH` to its `node_modules`, and run:

```sh
node tools/modern-preview-server.mjs --port 8765
```

The server binds only `127.0.0.1` and clearly labels fixture mode. Chrome is the
default; `PLAYWRIGHT_CHANNEL=chromium` uses an installed Playwright Chromium.
Run `node tests/modern-browser.test.mjs` for end-to-end checks and screenshots.
Deployment still requires device validation of actual snapshot/FUSE permissions,
the retention timer, and preview performance on the target hardware.
