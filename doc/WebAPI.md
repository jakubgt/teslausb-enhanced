# TeslaUSB local web API

TeslaUSB exposes a versioned, same-origin API at `/api/v1`. It is intended for
the dashboard and trusted tools on the same private network as the device. It
is not an Internet-facing remote-control API.

## Request rules

- Read-only routes use `GET`.
- Every state-changing route uses `POST` and must include
  `X-TeslaUSB-Request: 1`.
- Requests must use the device's local hostname or a private/link-local IP.
  Add custom fully qualified names (including Tailscale MagicDNS names) to the
  comma- or space-separated `WEB_ALLOWED_HOSTS` setting. Values are exact DNS
  names/IPs without URL schemes, paths, wildcards, or ports.
- Responses are not cached. API action responses use JSON with an `ok` field.
- Positional query arguments use percent encoding and retain the legacy file
  browser order so clients can migrate without changing their path model.

Example:

```console
curl -X POST \
  -H 'X-TeslaUSB-Request: 1' \
  http://teslausb.local/api/v1/actions/sync
```

## Routes

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/api/v1/capabilities` | Discover the API version and routes |
| `GET` | `/api/v1/status` | Hardware, network, storage, archive health, and encrypted-clip detection |
| `GET` | `/api/v1/maintenance` | Read-only SSH, storage/clock/snapshot/recovery evidence, and maintenance-log availability |
| `GET` | `/api/v1/maintenance/logs/{diagnostics,archiveloop,setup,maintenance}` | Download one fixed maintenance report/log; no arbitrary path arguments |
| `GET` | `/api/v1/config` | Discover configured virtual drives and BLE |
| `GET` | `/api/v1/videos` | Legacy complete list, or day-scoped linked recordings with `day=latest` / `day=YYYY-MM-DD` |
| `GET` | `/api/v1/speed-test?SECONDS` | Stream bounded test data; `SECONDS` is 1–30 (the bundled UI requests 15) |
| `GET` | `/api/v1/ble/status` | Read BLE pairing state |
| `POST` | `/api/v1/actions/sync` | Trigger archive synchronization |
| `POST` | `/api/v1/actions/reboot` | Queue a Raspberry Pi restart |
| `POST` | `/api/v1/actions/drives/toggle` | Enable or disable the USB gadget |
| `POST` | `/api/v1/actions/drives/repair` | Manually rebuild and verify the USB gadget (60-second rate limit) |
| `POST` | `/api/v1/actions/diagnostics` | Regenerate the diagnostic report |
| `POST` | `/api/v1/actions/ble/pair` | Start BLE key pairing |
| `GET` | `/api/v1/files/list` | List a managed media directory |
| `GET` | `/api/v1/files/download` | Download one managed media file |
| `GET` | `/api/v1/files/download-zip` | Download managed media as ZIP |
| `POST` | `/api/v1/files/upload` | Upload one managed media file |
| `POST` | `/api/v1/files/copy` | Copy managed media |
| `POST` | `/api/v1/files/move` | Move or rename managed media |
| `POST` | `/api/v1/files/delete` | Delete managed media |
| `POST` | `/api/v1/files/mkdir` | Create managed media directories |

The old `/cgi-bin/*.sh` read routes remain available. Legacy GET-based action
routes are a deprecated compatibility shim for existing releases of the
separately distributed WebUI; browser calls are accepted only with same-origin
evidence. New integrations should use `/api/v1` exclusively.

File routes currently preserve the legacy positional query format. For example, list the root of the Music drive with `/api/v1/files/list?fs%2FMusic&.`. The list response remains line-oriented text for compatibility; `/status`, `/config`, `/videos`, BLE status, and action responses are JSON. Mutation failures use a non-2xx status with `{"ok":false,"error":"..."}`; clients should handle both the HTTP status and JSON error instead of assuming a successful body.

The status response includes an `encrypted_clips` object with `available`,
`schema_version`, `detected`, `locations`, `checked_at`, and `message` fields.
It is detection metadata only: the endpoint never exposes clip contents,
credentials, account tokens, or decryption material. `available: false` means the
detector has not yet produced a trusted status file, not that encryption is
necessarily absent.

The additive `camera_drive_state` field describes the camera's USB presentation:
`disabled`, `prepared`, `paused`, `unavailable`, `connecting`, `connected`,
`suspended`, `disconnected`, or `unknown`. `connected` requires a bound UDC, the
configured camera LUN, and the kernel's host-configured state. `usb_state` is the
raw controller state, or `unknown` when unreadable. These fields do not assert
that Tesla is writing recordings. The legacy `drives_active` yes/no field is
retained for enable/disable compatibility and only indicates gadget preparation.

Maintenance reads never change SSH configuration or account credentials, and
require the same host and authentication boundary as the rest of the dashboard.
The SSH service state does not confirm login eligibility or a reachable listener.
Port 22, when offered, is an explicitly unverified default, not a configuration
probe. Unknown service status must not be displayed as a working SSH connection.
Log downloads use fixed server-side paths and attachment responses; missing or
unreadable files produce errors. Only the latest 8 MiB is returned for a larger
log, with an explicit truncation header. These endpoints do not generate fresh
diagnostics; use the existing protected POST action when a fresh report is needed.

## Recording-list scope and freshness

`GET /api/v1/videos` retains the legacy JSON shape `{"videos":[...]}` and
complete-index scope. The legacy CGI route remains line-oriented text. A
numeric `_` cache-buster is accepted at most once with no effect on scope:
one to twenty ASCII timestamp digits, or the older random-number format
`0.[1–20 ASCII digits]` (including zero). A sole bare random value, such as
`?0.123456789`, also retains the legacy full-list response. Bounded scientific
random values below one are accepted as well: a nonzero single-digit mantissa
with up to nineteen fractional digits and a negative one-to-two-digit
exponent, such as `1.1102230246251565e-16`. Leading signs, nonfinite values, arbitrary
floating-point syntax, and mixed bare/named arguments are rejected. New clients should use:

```text
/api/v1/videos?day=latest
/api/v1/videos?day=2026-09-07
/api/v1/videos?day=2026-09-07&_=1788782400000
```

For named parameters, only `day` and `_` are accepted, at most once each; malformed escapes, unknown
parameters, non-calendar dates, and nonnumeric cache-busters return `400`.
The total query is bounded to 128 ASCII characters. A day request returns:

```json
{
  "videos": ["RecentClips/2026-09-07/2026-09-07_12-00-00-front.mp4"],
  "available_days": ["2026-09-07", "2026-09-06"],
  "selected_day": "2026-09-07",
  "generated_at": "2026-09-07T12:05:00Z",
  "newest_recording": "2026-09-07_12-00-00"
}
```

- `available_days` lists recognized index folders, newest first. A listed day
  may no longer contain playable targets; this is not a per-day clip count.
- `day=latest` chooses the newest indexed day with an eligible MP4, falling
  back past empty/broken-only days. If none is available, `selected_day` and
  `newest_recording` are null and `videos` is empty. An explicit valid day stays
  selected even if its list is empty.
- `newest_recording` is the newest recognized camera filename timestamp in
  that response, not UTC or a verified recording time. No timezone is supplied
  by the filename. `generated_at` is the Pi's response-generation wall time,
  not proof that its clock is synchronized.
- Listing resolves index/target metadata, not recording contents, and excludes
  encrypted paths and broken targets. It does not force a snapshot or inspect
  the live camera filesystem. Available-day discovery is shallow; target
  validation is scoped to the requested day, or the latest-day fallback.

One scan per web-worker UID runs at a time; contention returns `503` rather
than queueing another scan. The scan has a 20-second deadline and a bounded
entry budget. Timeouts, unreadable indexes, and budget exhaustion return `503`,
not a successful empty or partial list. The bundled browser uses a separate
30-second request timeout and retains its previous library after failure.

## Maintenance health contract

The existing `schema_version: 1`, `ssh`, and `logs` fields are retained.
An additive `health` object has its own `schema_version: 1`:

| Field | Meaning |
| --- | --- |
| `storage.backing`, `storage.mutable` | `available`, `total_bytes`, `free_bytes`, and `available_bytes` for the actual dedicated filesystem; an unmounted placeholder is unavailable, not root free space |
| `storage.backing.cleanup_reserve_bytes` | Exactly `10737418240 + floor(total_bytes / 33)`; `below_cleanup_reserve` compares the runtime's `f_bfree` bytes with this threshold |
| `storage.live_camera` | Always `available: false`, `reason: "not_inspected"`; no mount or live free-space probe |
| `read_only.root`, `read_only.boot` | Boolean mount-state observations, or null when unknown |
| `snapshots` | `available`, `scan_complete`, `completed_count`, and `last_completed` (object or null); only finalized, protected `snap.bin.toc` metadata counts |
| `snapshots.last_completed` | `name`, `completed_at_utc`, `time_source: "toc_mtime"`; timestamp is TOC file metadata, not clip capture time or a guarantee that the Pi clock was correct |
| `cleanup` | Bounded log-tail evidence: `completed_release`, `release_attempt`, `none_in_log_tail`, or `unavailable`; nullable `last_attempt_at_utc`, `last_released_at_utc`, `last_released_snapshot`, plus `tail_limited: true` |
| `clock` | `available`, `state`, `last_verified_utc`, `observed_utc`, `fallback_utc`, and `age_seconds` of the saved worker status; not continuous synchronization proof |
| `recovery` | `available`, `scan_complete`, bounded `items` with bundle `name`, `file_count`, `logical_bytes`, `allocated_bytes`, plus corresponding totals and `allocation_note` |

`free_bytes` uses all free blocks (`f_bfree`), as the root cleanup worker does;
`available_bytes` uses `f_bavail`. Null means unknown, never zero or healthy.
Incomplete/unavailable inventories must not be presented as complete totals.
Recovery allocation uses `st_blocks * 512`; shared reflink extents can be counted
more than once. It is not uniquely owned or reclaimable space. No backup-delete
or shell action is added.

The unprivileged CGI invokes only the exact sudo action
`/usr/local/sbin/teslausb-web-sudo maintenance-health`, with no additional
arguments. The dispatcher checks the fixed root-owned helper path and runs
isolated Python. Its root-only scan is read-only and bounded to four seconds;
the caller has a six-second deadline and validates a bounded, allowlisted JSON
schema. Private clock state and fixed-scope recovery metadata can therefore be
reported without exposing credentials, keys, arbitrary paths, or command
execution authority. Snapshot images and recording contents are never read.

Cleanup evidence examines only the latest 256 KiB of `archiveloop.log`. A
historical `releasing snapshot ...` line is an attempt, not success. The new
`released snapshot snap-NNNNNN at <UTC>` marker follows required deletion and
verified unmount/no-mount evidence. It proves neither a specific byte recovery
nor a complete rollover cycle; old locale timestamps may remain null rather
than having their timezone guessed.

## Gadget repair

The gadget-repair route is intentionally manual and has no legacy GET form.
It briefly disconnects all virtual drives, rebuilds the configfs mass-storage
gadget, and verifies the UDC binding and each expected LUN. Concurrent requests
and requests made within 60 seconds of the previous attempt return `429`; a
failed post-repair verification leaves the gadget disconnected instead of
exposing an uncertain device state.
