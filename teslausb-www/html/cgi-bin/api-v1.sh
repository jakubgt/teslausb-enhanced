#!/bin/bash

# Versioned HTTP API dispatcher. Nginx maps /api/v1/... here and preserves
# PATH_INFO. Positional query arguments intentionally match the legacy CGI
# endpoints so clients can migrate without changing path encoding semantics.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
export TESLAUSB_API_VERSION=1
export TESLAUSB_API_RESPONSE=json
# shellcheck source=teslausb-www/html/cgi-bin/cgi-common.sh
source "$script_dir/cgi-common.sh"

route="${PATH_INFO:-${REQUEST_URI%%\?*}}"
route="${route#/api/v1}"
route="/${route#/}"
if [[ "$route" != / ]]
then
  route="${route%/}"
fi

# Enforce the v1 mutation contract at the dispatcher boundary as well as in
# each legacy-compatible implementation. This keeps a newly added route from
# accidentally inheriting the historical GET behavior.
case "$route" in
  /actions/sync|/actions/reboot|/actions/drives/toggle|/actions/drives/repair|/actions/diagnostics|/actions/ble/pair|\
  /files/upload|/files/copy|/files/move|/files/delete|/files/mkdir|\
  /trash/move|/trash/restore|/trash/delete)
    cgi_require_method POST
    cgi_require_mutation
    ;;
esac

case "$route" in
  /|/capabilities)
    cgi_require_method GET
    cgi_headers '200 OK' 'application/json; charset=utf-8'
    cat <<'EOF'
{
  "api_version": 1,
  "mutations": "POST",
  "csrf_header": "X-TeslaUSB-Request: 1",
  "legacy_get_mutations": "deprecated",
  "routes": {
    "status": "/api/v1/status",
    "maintenance": "/api/v1/maintenance",
    "maintenance_logs": ["diagnostics", "archiveloop", "setup", "maintenance"],
    "config": "/api/v1/config",
    "videos": "/api/v1/videos",
    "recording_downloads": "/api/v1/recordings/download",
    "recording_previews": "/api/v1/recordings/preview",
    "trash": "/api/v1/trash",
    "speed_test": "/api/v1/speed-test",
    "ble_status": "/api/v1/ble/status",
    "actions": ["sync", "reboot", "drives/toggle", "drives/repair", "diagnostics", "ble/pair"],
    "files": ["list", "download", "download-zip", "upload", "copy", "move", "delete", "mkdir"]
  }
}
EOF
    ;;
  /status|/health)
    exec "$script_dir/status.sh"
    ;;
  /maintenance|/maintenance/logs/diagnostics|/maintenance/logs/archiveloop|/maintenance/logs/setup|/maintenance/logs/maintenance)
    exec "$script_dir/maintenance.sh"
    ;;
  /config)
    exec "$script_dir/config.sh"
    ;;
  /videos)
    exec "$script_dir/videolist.sh"
    ;;
  /recordings/download|/recordings/preview|/recordings/preview/media|/trash/download)
    exec "$script_dir/recording-media.sh"
    ;;
  /trash|/trash/media|/trash/move|/trash/restore|/trash/delete)
    exec "$script_dir/recording-trash.sh"
    ;;
  /speed-test)
    exec "$script_dir/randomdata.sh"
    ;;
  /ble/status)
    exec "$script_dir/checkBLEstatus.sh"
    ;;
  /actions/sync)
    cgi_require_method POST
    exec "$script_dir/trigger_sync.sh"
    ;;
  /actions/reboot)
    cgi_require_method POST
    exec "$script_dir/reboot.sh"
    ;;
  /actions/drives/toggle)
    cgi_require_method POST
    exec "$script_dir/toggledrives.sh"
    ;;
  /actions/drives/repair)
    cgi_require_method POST
    exec "$script_dir/repairgadget.sh"
    ;;
  /actions/diagnostics)
    cgi_require_method POST
    exec "$script_dir/diagnose.sh"
    ;;
  /actions/ble/pair)
    cgi_require_method POST
    exec "$script_dir/pairBLEkey.sh"
    ;;
  /files/list)
    exec "$script_dir/ls.sh"
    ;;
  /files/download)
    exec "$script_dir/download.sh"
    ;;
  /files/download-zip)
    exec "$script_dir/downloadzip.sh"
    ;;
  /files/upload)
    cgi_require_method POST
    exec "$script_dir/upload.sh"
    ;;
  /files/copy)
    cgi_require_method POST
    exec "$script_dir/cp.sh"
    ;;
  /files/move)
    cgi_require_method POST
    exec "$script_dir/mv.sh"
    ;;
  /files/delete)
    cgi_require_method POST
    exec "$script_dir/rm.sh"
    ;;
  /files/mkdir)
    cgi_require_method POST
    exec "$script_dir/mkdir.sh"
    ;;
  *)
    cgi_error '404 Not Found' 'Unknown API route.'
    ;;
esac
