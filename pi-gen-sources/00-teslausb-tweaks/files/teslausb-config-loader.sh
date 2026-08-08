#!/bin/bash

# This file is sourced by first boot and setup. JSON values are validated by a
# fixed Python allowlist and transferred as NUL-delimited data. Nothing from a
# JSON document is evaluated as shell syntax.

# setup-teslausb can source this file directly and then source envsetup.sh,
# which discovers it again. Keep the loader idempotent so readonly schema data
# is not reassigned on that compatibility path.
if [ "${TESLAUSB_DECLARATIVE_LOADER_INITIALIZED:-false}" = true ] &&
   declare -F teslausb_load_config > /dev/null
then
  return 0
fi
readonly TESLAUSB_DECLARATIVE_LOADER_INITIALIZED=true

# This second, fixed allowlist is intentional defense in depth. Even if a
# staged validator is replaced or malfunctions, it cannot ask this loader to
# overwrite shell-control variables such as PATH, BASH_ENV, or LD_PRELOAD.
readonly TESLAUSB_CONFIG_RELEASE_STATE_DIR="${TESLAUSB_CONFIG_RELEASE_STATE_DIR:-/mutable/teslausb/application-releases}"
readonly TESLAUSB_CONFIG_LIVE_BIN="${TESLAUSB_CONFIG_LIVE_BIN:-/root/bin}"
readonly -a TESLAUSB_DECLARATIVE_ALLOWED_NAMES=(
  AP_IP
  AP_PASS
  AP_SSID
  ARCHIVE_DELAY
  ARCHIVE_RECENTCLIPS
  ARCHIVE_RETRY_ATTEMPTS_PER_RUN
  ARCHIVE_RETRY_BASE_SECONDS
  ARCHIVE_RETRY_MAX_SECONDS
  ARCHIVE_RSYNC_TIMEOUT
  ARCHIVE_SAVEDCLIPS
  ARCHIVE_SENTRYCLIPS
  ARCHIVE_SERVER
  ARCHIVE_SYSTEM
  ARCHIVE_TRACKMODECLIPS
  AUTOFS_WAIT_SECONDS
  AWS_ACCESS_KEY_ID
  AWS_REGION
  AWS_SECRET_ACCESS_KEY
  AWS_SNS_TOPIC_ARN
  BOOMBOX_SIZE
  BRANCH
  CAM_SIZE
  CIFS_SEC
  CIFS_VERSION
  CONFIGURE_ARCHIVING
  CPU_GOVERNOR
  DATA_DRIVE
  DIRTY_BACKGROUND_BYTES
  DIRTY_RATIO
  DISCORD_ENABLED
  DISCORD_WEBHOOK_URL
  FORCE_SYNC_TIMEOUT_SECONDS
  GOTIFY_APP_TOKEN
  GOTIFY_DOMAIN
  GOTIFY_ENABLED
  GOTIFY_PRIORITY
  IFTTT_ENABLED
  IFTTT_EVENT_NAME
  IFTTT_KEY
  INCREASE_ROOT_SIZE
  INSTALL_USER_REQUESTED_PACKAGES
  KEEP_AWAKE_WEBHOOK_URL
  LIGHTSHOW_SIZE
  MATRIX_ENABLED
  MATRIX_PASSWORD
  MATRIX_ROOM
  MATRIX_SERVER_URL
  MATRIX_USERNAME
  MUSIC_RSYNC_TIMEOUT
  MUSIC_SHARE_NAME
  MUSIC_SIZE
  NOTIFICATION_COMMAND_ENABLED
  NOTIFICATION_COMMAND_FINISH
  NOTIFICATION_COMMAND_START
  NOTIFICATION_TITLE
  NTFY_ENABLED
  NTFY_PRIORITY
  NTFY_TOKEN
  NTFY_URL
  PIP_RETRIES
  PIP_TIMEOUT_SECONDS
  PUSHOVER_APP_KEY
  PUSHOVER_ENABLED
  PUSHOVER_USER_KEY
  RCLONE_CONNECT_TIMEOUT
  RCLONE_DRIVE
  RCLONE_FLAGS
  RCLONE_IO_TIMEOUT
  RCLONE_PATH
  REPO
  RSYNC_PATH
  RSYNC_SERVER
  RSYNC_SSH_CONNECT_TIMEOUT
  RSYNC_USER
  SAMBA_ENABLED
  SAMBA_GUEST
  SAMBA_PASSWORD
  SAMBA_USER
  SENTRY_CASE
  SHARE_DOMAIN
  SHARE_NAME
  SHARE_PASSWORD
  SHARE_USER
  SIGNAL_ENABLED
  SIGNAL_FROM_NUM
  SIGNAL_TO_NUM
  SIGNAL_URL
  SKIP_READONLY
  SLACK_ENABLED
  SLACK_WEBHOOK_URL
  SNAPSHOTS_ENABLED
  SNAPSHOT_INTERVAL
  SNS_ENABLED
  SSH_ALLOW_DEFAULT_PASSWORD
  SSH_DISABLE_PASSWORD_AUTHENTICATION
  SSH_ROOT_PUBLIC_KEY
  SSH_USER_PASSWORD
  SSID
  TELEGRAM_BOT_TOKEN
  TELEGRAM_CHAT_ID
  TELEGRAM_ENABLED
  TELEGRAM_SILENT_NOTIFY
  TEMPERATURE_CAUTION
  TEMPERATURE_INTERVAL
  TEMPERATURE_POSTARCHIVE
  TEMPERATURE_WARNING
  TESLAFI_API_TOKEN
  TESLAUSB_CURL_CONNECT_TIMEOUT
  TESLAUSB_CURL_MAX_TIME
  TESLAUSB_HOSTNAME
  TESLAUSB_NOTIFICATION_TIMEOUT_SECONDS
  TESLA_BLE_ARTIFACT_FILE
  TESLA_BLE_ARTIFACT_MAX_BYTES
  TESLA_BLE_ARTIFACT_SHA256
  TESLA_BLE_ARTIFACT_VERSION
  TESLA_BLE_COMMAND_TIMEOUT_SECONDS
  TESLA_BLE_VIN
  TESSIE_API_TOKEN
  TESSIE_VIN
  TIME_ZONE
  TRIGGER_FILE_ANY
  TRIGGER_FILE_RECENT
  TRIGGER_FILE_SAVED
  TRIGGER_FILE_SENTRY
  UPGRADE_PACKAGES
  USE_EXFAT
  WEBHOOK_ENABLED
  WEBHOOK_URL
  WEB_ALLOWED_HOSTS
  WEB_AUTH_DISABLED
  WEB_PASSWORD
  WEB_USERNAME
  WEBUI_RELEASE
  WEBUI_SHA256
  WIFIPASS
  WIFI_COUNTRY
)
readonly -a TESLAUSB_DECLARATIVE_BOOLEAN_NAMES=(
  ARCHIVE_RECENTCLIPS ARCHIVE_SAVEDCLIPS ARCHIVE_SENTRYCLIPS
  ARCHIVE_TRACKMODECLIPS CONFIGURE_ARCHIVING DISCORD_ENABLED GOTIFY_ENABLED
  IFTTT_ENABLED MATRIX_ENABLED NOTIFICATION_COMMAND_ENABLED NTFY_ENABLED
  PUSHOVER_ENABLED SAMBA_ENABLED SAMBA_GUEST SIGNAL_ENABLED SKIP_READONLY
  SLACK_ENABLED SNAPSHOTS_ENABLED SNS_ENABLED SSH_ALLOW_DEFAULT_PASSWORD
  SSH_DISABLE_PASSWORD_AUTHENTICATION TELEGRAM_ENABLED TELEGRAM_SILENT_NOTIFY
  TEMPERATURE_POSTARCHIVE UPGRADE_PACKAGES USE_EXFAT WEBHOOK_ENABLED
  WEB_AUTH_DISABLED
)
readonly -a TESLAUSB_DECLARATIVE_INTEGER_NAMES=(
  ARCHIVE_DELAY ARCHIVE_RETRY_ATTEMPTS_PER_RUN ARCHIVE_RETRY_BASE_SECONDS
  ARCHIVE_RETRY_MAX_SECONDS ARCHIVE_RSYNC_TIMEOUT AUTOFS_WAIT_SECONDS
  DIRTY_BACKGROUND_BYTES DIRTY_RATIO FORCE_SYNC_TIMEOUT_SECONDS GOTIFY_PRIORITY
  MUSIC_RSYNC_TIMEOUT NTFY_PRIORITY PIP_RETRIES PIP_TIMEOUT_SECONDS
  RCLONE_CONNECT_TIMEOUT RCLONE_IO_TIMEOUT RSYNC_SSH_CONNECT_TIMEOUT
  SENTRY_CASE SNAPSHOT_INTERVAL TEMPERATURE_CAUTION TEMPERATURE_INTERVAL
  TEMPERATURE_WARNING TESLAUSB_CURL_CONNECT_TIMEOUT TESLAUSB_CURL_MAX_TIME
  TESLAUSB_NOTIFICATION_TIMEOUT_SECONDS TESLA_BLE_ARTIFACT_MAX_BYTES
  TESLA_BLE_COMMAND_TIMEOUT_SECONDS
)
readonly -a TESLAUSB_DECLARATIVE_ARRAY_NAMES=(
  INSTALL_USER_REQUESTED_PACKAGES RCLONE_FLAGS
)

teslausb_config_message() {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "$*"
  elif declare -F setup_config_message > /dev/null
  then
    setup_config_message "$*"
  else
    printf '%s\n' "$*" >&2
  fi
}

teslausb_config_name_is_allowed() {
  local candidate="$1"
  local allowed_name
  for allowed_name in "${TESLAUSB_DECLARATIVE_ALLOWED_NAMES[@]}"
  do
    if [ "$candidate" = "$allowed_name" ]
    then
      return 0
    fi
  done
  return 1
}

teslausb_config_name_in_list() {
  local candidate="$1"
  shift
  local list_name
  for list_name in "$@"
  do
    [ "$candidate" = "$list_name" ] && return 0
  done
  return 1
}

teslausb_config_directory_is_trusted() {
  local candidate="$1"
  local metadata owner_id group_id mode
  if [ -L "$candidate" ] || [ ! -d "$candidate" ]
  then
    return 1
  fi
  metadata="$(stat -c '%u:%g:%a' -- "$candidate")" || return 1
  IFS=: read -r owner_id group_id mode <<< "$metadata"
  [ "$owner_id" = 0 ] && [ "$group_id" = 0 ] &&
    [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 0022) == 0 ))
}

teslausb_config_regular_path_is_trusted() {
  local candidate="$1"
  local metadata owner_id group_id mode parent
  if [ -L "$candidate" ] || [ ! -f "$candidate" ] || [ ! -x "$candidate" ]
  then
    return 1
  fi
  metadata="$(stat -c '%u:%g:%a' -- "$candidate")" || return 1
  IFS=: read -r owner_id group_id mode <<< "$metadata"
  if [ "$owner_id" != 0 ] || [ "$group_id" != 0 ] ||
     ! [[ "$mode" =~ ^[0-7]+$ ]] || (( (8#$mode & 0022) != 0 ))
  then
    return 1
  fi
  parent="$(dirname -- "$candidate")"
  teslausb_config_directory_is_trusted "$parent"
}

teslausb_config_transactional_path_is_trusted() {
  local candidate="$1"
  local expected_link releases_root resolved_target
  [ "$candidate" = "$TESLAUSB_CONFIG_LIVE_BIN/teslausb_config.py" ] || return 1
  [ -L "$candidate" ] || return 1
  expected_link="$TESLAUSB_CONFIG_RELEASE_STATE_DIR/current/root-bin/teslausb_config.py"
  [ "$(readlink -- "$candidate")" = "$expected_link" ] || return 1
  [ -L "$TESLAUSB_CONFIG_RELEASE_STATE_DIR/current" ] || return 1
  teslausb_config_directory_is_trusted "$TESLAUSB_CONFIG_RELEASE_STATE_DIR" || return 1
  teslausb_config_directory_is_trusted "$TESLAUSB_CONFIG_RELEASE_STATE_DIR/releases" || return 1
  teslausb_config_directory_is_trusted "$TESLAUSB_CONFIG_LIVE_BIN" || return 1
  releases_root="$(readlink -f -- "$TESLAUSB_CONFIG_RELEASE_STATE_DIR/releases")" || return 1
  resolved_target="$(readlink -f -- "$candidate")" || return 1
  case "$resolved_target" in
    "$releases_root"/*/root-bin/teslausb_config.py) ;;
    *) return 1 ;;
  esac
  teslausb_config_regular_path_is_trusted "$resolved_target"
}

teslausb_config_path_is_trusted() {
  local candidate="$1"
  if [ -L "$candidate" ]
  then
    teslausb_config_transactional_path_is_trusted "$candidate"
  else
    teslausb_config_regular_path_is_trusted "$candidate"
  fi
}

teslausb_config_override_is_trusted() {
  local candidate="$1"
  local upgrade_root expected candidate_real metadata owner_id group_id mode
  if [ -z "${TESLAUSB_UPGRADE_DIR:-}" ] || [ -L "$TESLAUSB_UPGRADE_DIR" ] ||
     [ ! -d "$TESLAUSB_UPGRADE_DIR" ]
  then
    return 1
  fi
  metadata="$(stat -c '%u:%g:%a' -- "$TESLAUSB_UPGRADE_DIR")" || return 1
  IFS=: read -r owner_id group_id mode <<< "$metadata"
  if [ "$owner_id" != 0 ] || [ "$group_id" != 0 ] || [ "$mode" != 700 ]
  then
    return 1
  fi
  upgrade_root="$(readlink -f -- "$TESLAUSB_UPGRADE_DIR")" || return 1
  candidate_real="$(readlink -f -- "$candidate")" || return 1
  expected="$upgrade_root/teslausb_config.py"
  [ "$candidate_real" = "$expected" ] && teslausb_config_path_is_trusted "$candidate"
}

teslausb_config_helper() {
  local candidate
  if [ -n "${TESLAUSB_CONFIG_HELPER:-}" ]
  then
    if teslausb_config_override_is_trusted "$TESLAUSB_CONFIG_HELPER"
    then
      printf '%s\n' "$TESLAUSB_CONFIG_HELPER"
      return
    fi
    teslausb_config_message \
      "STOP: TESLAUSB_CONFIG_HELPER must be the trusted helper in the private upgrade directory."
    return 1
  fi
  for candidate in "$TESLAUSB_CONFIG_LIVE_BIN/teslausb_config.py" \
    /usr/local/lib/teslausb/teslausb_config.py
  do
    if teslausb_config_path_is_trusted "$candidate"
    then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
}

teslausb_secure_config() {
  local setup_config="$1"
  local metadata owner_id group_id mode
  if [ -L "$setup_config" ] || [ ! -f "$setup_config" ]
  then
    teslausb_config_message "STOP: $setup_config must be a regular file, not a symbolic link."
    return 1
  fi
  metadata="$(stat -c '%u:%g:%a' -- "$setup_config")" || return 1
  IFS=: read -r owner_id group_id mode <<< "$metadata"
  if [ "$owner_id" != 0 ] || [ "$group_id" != 0 ]
  then
    teslausb_config_message "STOP: $setup_config must be owned by root:root."
    return 1
  fi
  if [ "$mode" != 600 ] && ! chmod 0600 -- "$setup_config"
  then
    teslausb_config_message "STOP: unable to protect $setup_config with mode 0600."
    return 1
  fi
  [ "$(stat -c '%a' -- "$setup_config")" = 600 ] || {
    teslausb_config_message "STOP: $setup_config must have mode 0600."
    return 1
  }
}

teslausb_assign_config_array() {
  local name="$1"
  shift
  declare -g -a "$name"
  local -n destination="$name"
  destination=("$@")
}

teslausb_load_json_config() {
  local setup_config="$1"
  local helper kind name value count index offset emitter_pid
  local -a records=() values=()
  teslausb_secure_config "$setup_config" || return 1
  helper="$(teslausb_config_helper)" || {
    teslausb_config_message "STOP: the declarative configuration validator is unavailable."
    return 1
  }
  "$helper" validate "$setup_config" || return 1
  # A named coprocess lets us consume NUL-delimited records without putting
  # secrets on disk while still checking the emitter's exit status. Process
  # substitution would otherwise hide a failed second read of the file.
  coproc TESLAUSB_CONFIG_EMITTER { "$helper" emit0 "$setup_config"; }
  emitter_pid=$TESLAUSB_CONFIG_EMITTER_PID
  mapfile -d '' -t records <&"${TESLAUSB_CONFIG_EMITTER[0]}"
  if ! wait "$emitter_pid"
  then
    teslausb_config_message "STOP: unable to load the validated declarative configuration."
    return 1
  fi
  offset=0
  while (( offset < ${#records[@]} ))
  do
    kind=${records[offset++]}
    name=${records[offset++]:-}
    if ! [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
       ! teslausb_config_name_is_allowed "$name"
    then
      teslausb_config_message "STOP: the validator returned an unsupported variable name."
      return 1
    fi
    case "$kind" in
      S)
        (( offset < ${#records[@]} )) || return 1
        value=${records[offset++]}
        if teslausb_config_name_in_list "$name" "${TESLAUSB_DECLARATIVE_ARRAY_NAMES[@]}" ||
           (( ${#value} > 16384 ))
        then
          teslausb_config_message "STOP: the validator returned an invalid scalar record."
          return 1
        fi
        if teslausb_config_name_in_list "$name" "${TESLAUSB_DECLARATIVE_BOOLEAN_NAMES[@]}" &&
           [ "$value" != true ] && [ "$value" != false ]
        then
          teslausb_config_message "STOP: the validator returned an invalid boolean record."
          return 1
        fi
        if teslausb_config_name_in_list "$name" "${TESLAUSB_DECLARATIVE_INTEGER_NAMES[@]}" &&
           ! [[ "$value" =~ ^-?[0-9]+$ ]]
        then
          teslausb_config_message "STOP: the validator returned an invalid integer record."
          return 1
        fi
        printf -v "$name" '%s' "$value"
        export "$name"
        ;;
      A)
        (( offset < ${#records[@]} )) || return 1
        count=${records[offset++]}
        if ! teslausb_config_name_in_list "$name" "${TESLAUSB_DECLARATIVE_ARRAY_NAMES[@]}" ||
           ! [[ "$count" =~ ^[0-9]+$ ]] || (( count > 128 ))
        then
          teslausb_config_message "STOP: the validator returned an invalid array record."
          return 1
        fi
        (( offset + count <= ${#records[@]} )) || return 1
        values=()
        for (( index=0; index<count; index++ ))
        do
          value=${records[offset++]}
          if (( ${#value} > 16384 ))
          then
            teslausb_config_message "STOP: the validator returned an oversized array value."
            return 1
          fi
          values+=("$value")
        done
        teslausb_assign_config_array "$name" "${values[@]}"
        ;;
      *)
        teslausb_config_message "STOP: the validator returned an invalid record type."
        return 1
        ;;
    esac
  done
  export TESLAUSB_CONFIG_FORMAT=json
  export TESLAUSB_CONFIG_PATH="$setup_config"
}

teslausb_load_legacy_config() {
  local setup_config="$1" failure_output
  teslausb_secure_config "$setup_config" || return 1
  teslausb_config_message "WARNING: legacy executable Bash configuration is deprecated; migrate to teslausb_setup.json."
  if ! failure_output="$(
    (
      set -eu
      # shellcheck disable=SC1090 # Legacy compatibility path; file is root-owned.
      source "$setup_config"
    ) 2>&1
  )"
  then
    teslausb_config_message "Error in $setup_config:"
    teslausb_config_message "$failure_output"
    return 1
  fi
  # shellcheck disable=SC1090 # Legacy compatibility path; file is root-owned.
  source "$setup_config"
  export TESLAUSB_CONFIG_FORMAT=legacy-shell
  export TESLAUSB_CONFIG_PATH="$setup_config"
}

teslausb_load_config() {
  local requested="${1:-}"
  if [ -z "$requested" ]
  then
    if [ -e /root/teslausb_setup.json ]
    then
      requested=/root/teslausb_setup.json
      if [ -e /root/teslausb_setup_variables.conf ]
      then
        teslausb_config_message "WARNING: both setup formats exist; using teslausb_setup.json and ignoring the legacy file."
      fi
    else
      requested=/root/teslausb_setup_variables.conf
    fi
  fi
  case "$requested" in
    *.json) teslausb_load_json_config "$requested" ;;
    *.conf) teslausb_load_legacy_config "$requested" ;;
    *)
      teslausb_config_message "STOP: setup configuration must end in .json or .conf."
      return 1
      ;;
  esac
}
