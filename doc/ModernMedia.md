# Recording downloads and Low previews

These endpoints use the normal nginx authentication/allowed-host boundary and
the shared CGI origin checks. Requests are same-origin. None accepts a device
path, shell command, URL to fetch, or configurable filesystem root.

## Original downloads

`GET /api/v1/recordings/download?event=SentryClips/2026-09-07_14-30-00&camera=all&info=1`
returns preparation metadata: `files`, `file_count`, `total_bytes`, `format`,
`filename`, `download_url`, and `truncated:false`. `total_bytes` is the sum of
original file bytes, **not the final ZIP size**. Supported cameras are `front`,
`back`, `left_repeater`, `right_repeater`, `left_pillar`, and `right_pillar`.

Following `download_url` returns one MP4 when there is exactly one file, otherwise
an uncompressed streaming ZIP preserving every segment and camera as separate
original files. Omit `info=1` to download directly. An optional
`segment=2026-09-07_14-29-00` selects a specific minute across cameras; this is
particularly useful for clips inside `RecentClips/YYYY-MM-DD`.

Inside Trash, the explicit
`GET /api/v1/trash/download?id=<64-character-id>&camera=all&info=1` contract
provides the same metadata and downloads for a preserved trashed/restored owned
copy. Omit `info=1` to download it. Deleted or missing copies never fall through
to snapshot aliases. Ordinary recording endpoints cannot retrieve trashed clips.

The MP4 response has an exact Content-Length. ZIP responses have
`X-TeslaUSB-Source-Bytes` and `X-TeslaUSB-File-Count`, with no invented ZIP length.
Use indeterminate progress while preparing; during transfer use received bytes
and an approximate original-byte denominator for ZIP. Cancelling the request
stops further source reads. The browser/client must treat interrupted or failed
transfers as failures and offer retry, never report a partial archive as success.

Safety limits are 512 selected files, 512 MiB per segment, 16 GiB total, 20,000
scanned event entries, and 20 seconds of metadata preparation. Requests exceeding
these limits fail explicitly instead of silently truncating a selection.

The helper validates the literal index alias, permits only the fixed
`/tmp/snapshots/snap-######/TeslaCam/...` or equivalent
`/backingfiles/snapshots/snap-######/mnt/TeslaCam/...` spellings, then opens the
canonical snapshot through pinned directories with O_NOFOLLOW at every level.
It checks that the snapshot filesystem is read-only before opening video data.
Live camera mounts, disk image files, arbitrary aliases, traversal, nonregular
files, and literal or resolved aliases into EncryptedClips are rejected.

Original downloads bypass the playback FUSE ctts adjustment and preserve actual
source bytes. Ordinary browser High playback continues to use protected FUSE.
Trash tombstones are checked before source access. Restored events download
their private owned copies; hidden/deleted events are refused. Already opened
downloads may complete if the event is moved to Trash concurrently.
Timestamp-camera filenames in Trash's `hidden_media` set also suppress duplicate
Recent and other snapshot aliases, including after an owned copy is restored.

## Optional Low previews

`GET /api/v1/recordings/preview?path=SentryClips/<event>/<filename>.mp4`
returns `state`, `reason`, `original_url`, and `preview_url` (only when ready).
States are `not_requested`, `preparing`, `ready`, `failed`, or `unavailable`.

`POST` to the same URL, with `X-TeslaUSB-Request: 1`, requests generation. No body
is required. Preparation returns HTTP 202. A busy worker returns
`state:unavailable`, `reason:preview_worker_busy`, and `retry_after_seconds:5`;
clients may retry later or offer High. Nothing is queued in an unbounded queue.

`GET /api/v1/recordings/preview/media?path=...` serves a ready preview with single
HTTP byte-range support for seeking. The path is revalidated against the current
source and Trash state on every request. Cache identity includes file inode,
size and modification timestamp; old source identities cannot reuse a preview.

Low is actual H.264 transcoding: maximum 640-pixel width and 12 frames/second,
CRF 30, one thread, no audio. It is intended for individual Tesla minute files.
Segments over 65 seconds or 512 MiB are unavailable. The worker verifies output
duration and rejects incomplete output instead of serving an unlabeled excerpt.
Restored copies currently return `restored_original_only`, with their proper
owned original media URL. They are never mislabeled as Low.

Generation is optional and may take longer than playback duration on a small Pi.
Without `/usr/bin/ffmpeg`, `/usr/bin/ffprobe`, a usable encoder, or safe cache
storage, the API explicitly reports unavailable. The UI should offer High and
show preparation/error state rather than display original footage as Low.

Provision `/mutable/teslausb-previews` with owner `www-data:www-data` and mode
`0700`. Do not expose the cache as an nginx static directory. Files are mode
`0600`; a nonblocking inherited flock permits one worker. The cache is bounded
to 256 MiB with 32 MiB reserved per preview and seven-day eviction. Generation
requires at least 64 MiB free beyond the reserved output. ffmpeg is constrained
to 90 CPU seconds, a wall timeout below three minutes, 512 MiB address space,
32 MiB output, one thread, no external tracks and no network protocols. It is
launched without a shell, with fixed binaries and inherited approved source and
output descriptors. Source files and camera disk images are never modified.

The relevant ffmpeg options are documented in the official
[command documentation](https://ffmpeg.org/ffmpeg.html) and
[MOV/MP4 format documentation](https://ffmpeg.org/ffmpeg-formats.html).

## Integration and validation

Route `/api/v1/recordings/download`, `/api/v1/recordings/preview`, and
`/api/v1/recordings/preview/media`, plus `/api/v1/trash/download`, to executable
`cgi-bin/recording-media.sh`.
Provision the private preview and Trash roots during normal web setup. Deny
direct CGI access to Python implementation files in nginx. No new sudo action
or root service is required for media previews or downloads.

Run `python3 -m unittest discover -s tests -p test_recording_media.py` on Linux.
Tests verify path policy, real original byte integrity, streaming ZIP validity,
truthful unavailable states, HTTP ranges, cancellation, tombstones, restoration,
and symlink escape rejection. The Linux openat/read-only security cases are
explicitly skipped on Windows; a Windows-only pass is not deployment validation.
