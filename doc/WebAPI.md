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
| `GET` | `/api/v1/config` | Discover configured virtual drives and BLE |
| `GET` | `/api/v1/videos` | List linked TeslaCam recordings |
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

The gadget-repair route is intentionally manual and has no legacy GET form.
It briefly disconnects all virtual drives, rebuilds the configfs mass-storage
gadget, and verifies the UDC binding and each expected LUN. Concurrent requests
and requests made within 60 seconds of the previous attempt return `429`; a
failed post-repair verification leaves the gadget disconnected instead of
exposing an uncertain device state.
