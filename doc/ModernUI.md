# Modern TeslaUSB interface — version 2.0.0

The normal `/` landing page now opens the built-in modern interface. The same
interface is available at `/modern/`. **Classic UI** links remain available on
desktop and phones at `/index.html?ui=legacy`. Existing custom Vue configuration
and Classic files remain installed. No BLE controls are added to the modern UI.

## Recordings

The first screen opens the newest available recording in **Single camera**
with original quality.
Use **Camera overview** for small stills from all six angles, or **All cameras**
for synchronized original videos. This is the latest **completed
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
camera, timeline position, layout, speed, and playback intention when
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

The viewer's **Previous clip / Next clip** controls follow recorded time (earlier
and later) across all pages of the current category, hour, and search results.
The grid remains newest-first and follows the selected clip's page. Switching
clips preserves camera, layout, speed, and play/pause intent, starting
the new clip at zero. **Play next automatically** is off on every fresh page
load. When enabled, it advances after the final segment and stops at the end of
the filtered selection. Changing filters leaves the current clip intact; if it
falls outside the selection, navigation is disabled until a matching clip is
selected. No hidden-tab or paused-player autoplay is triggered.

The modern player uses **Original quality** only. It does not request on-device
Low video conversion or display an indefinite smaller-preview preparation state.
Use **Load clip first** when streaming buffers, or **Camera overview** to inspect
small stills before choosing one original camera video. Downloads retain the
original source bytes. The older Low API remains available for compatibility,
but the modern interface does not call it. See [media constraints and APIs](ModernMedia.md).

Recording cards show the front camera's first available keyframe from the first
recorded minute, with the play icon overlaid. They request only visible cards,
wait briefly before starting to avoid work during quick scrolling, and cancel
when a card or page is left. Card and overview requests share a sequential queue,
with the active viewer taking priority. Temporary delivery failures have bounded
retries; a failed or missing frame keeps a playable fallback instead of silently
using a later minute. When the first front camera is absent, an existing recording
thumbnail may be used; otherwise the card identifies the unavailable still.
Restored copies use an existing thumbnail when one was preserved.

**Load clip first** pauses streaming and loads the current recorded minute, for
the selected camera or all available cameras in the All cameras layout. It shows
per-camera byte progress and cancellation, fetches cameras sequentially, and keeps
the playable copy in this browser only. When ready, press Play. Loading is bounded
to 64 MiB per camera and 256 MiB total, with a 30-second inactivity timeout and
ten-minute overall limit. Oversized, failed, or incomplete transfers offer retry
or normal streaming; they never claim to be ready. The playable URL is used so
Tesla timestamp compatibility adjustments are retained. Original downloads still
preserve the exact source bytes. Changing camera, layout, minute, clip,
or leaving/hiding the viewer cancels transfers and releases loaded copies. Seeking
within the loaded minute retains its copy. A multi-minute event's next minute
streams normally unless loaded separately. Preloading addresses network waiting;
decoding six original videos still depends on the browser device's capabilities.

**Camera overview** requests small cached JPEGs only when selected. These are
stills near the start of the selected recorded minute, not live views or smooth
video playback. Clicking a tile opens Single camera with original quality.
Missing cameras and unavailable stills are labelled. Status and image requests run sequentially
to avoid competing for the recording store. Temporary delivery failures retry up
to three attempts; failed generation requires explicit Check overview.
In-progress work is checked for up to two minutes. Leaving the overview stops its
requests. Restored copies currently offer original playback without generated
stills. The six-camera still generation benchmark on the installed Pi took about
four seconds total; other footage and concurrent device work may take longer.

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

The Storage cards separate Trash, restored copies, total retained copies,
filesystem free space, protected reserve, and space above that reserve. Copy
totals are logical file sizes, not a promise of physical space reclaimed. Missing
figures stay unknown; incomplete or inconsistent reports are identified. An empty
Trash can still show restored copies, which remain preserved without automatic
expiry. To remove one, move its restored recording back to Trash and delete that
copy permanently. Empty Trash affects only copies currently in Trash.

**Trash uses additional storage.** The snapshot index is read-only. Deleting a
private recovery copy does not erase car recordings, archives, or original
snapshots; normal snapshot cleanup still controls those originals. Classic
directory listings retain their historical view. Restored copies stay preserved
until explicitly trashed again. Large events on slow storage may exceed the copy
deadline and fail with a visible retry message. See [storage and recovery
semantics](RecordingTrash.md) for exact behavior and limits.

## Device and Files

The connection banner is separate from USB status and records the browser's last
successful HTTP contact with TeslaUSB. A transport failure or browser offline
event shows **Connection lost** with **Retry**. HTTP errors still prove the server
responded; individual panels report the failed operation. Retry only reads status,
including explicit recovery from pending power actions. It never repeats a device
action or file mutation. Concurrent responses cannot let an older transport
failure overwrite newer contact. Power actions pause automatic status checks;
their completion remains unverified even if the device responds again.

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

The version 2.0.0 image bundles FFmpeg and verifies its JPEG encoder before
release. Normal web setup installs modern assets, exact API routes, private
www-data-owned directories on `/backingfiles` (mode 0700), and the hourly Trash
timer. On existing systems, optional FFmpeg installation failure leaves the web
interface usable with clear still-image fallbacks. The small `/mutable` partition
is reserved for existing runtime state; recording copies and media caches use
`/backingfiles`. The
web server explicitly serves trusted modern JavaScript modules with their script
content type; uploaded modules remain downloads. Device requests share the API's
timeout handling so a stalled connection is distinguished from cancellation. The
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
the retention timer, and still-image performance on the target hardware. A new
release image stays an unpublished draft until its exact checksum has completed
the spare-card setup, recording, archive, download, and recovery acceptance test.
