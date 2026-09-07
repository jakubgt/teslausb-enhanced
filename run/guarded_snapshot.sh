#!/bin/bash -eu

# Create a camera snapshot only after checking the live camera filesystem for
# entries in Tesla's EncryptedClips directory. The shared gadget-operation lock
# remains held from USB disconnect through the final block-level snapshot, so
# the car cannot add an encrypted entry between the check and the copy.

if [ "${BASH_SOURCE[0]}" != "$0" ]
then
  echo "${BASH_SOURCE[0]} must be executed, not sourced" >&2
  return 1
fi

leave_disconnected=false
connect_after_copy=false
snapshot_mode=
while [ "$#" -gt 0 ]
do
  case "$1" in
    --leave-disconnected)
      leave_disconnected=true
      ;;
    --connect-after-copy)
      connect_after_copy=true
      ;;
    fsck | nofsck)
      if [ -n "$snapshot_mode" ]
      then
        echo "only one snapshot mode may be specified" >&2
        exit 64
      fi
      snapshot_mode="$1"
      ;;
    *)
      echo "usage: $0 [--leave-disconnected|--connect-after-copy] [fsck|nofsck]" >&2
      exit 64
      ;;
  esac
  shift
done
if [ "$leave_disconnected" = true ] && [ "$connect_after_copy" = true ]
then
  echo "conflicting USB restore modes" >&2
  exit 64
fi

if [[ "${TESLAUSB_GUARDED_SNAPSHOT_TEST_OVERRIDES:-}" == 1 ]]
then
  gadget_lock_dir="${TESLAUSB_GADGET_RUN_DIR:-/run/teslausb}"
  cam_mount="${TESLAUSB_CAM_MOUNT:-/mnt/cam}"
  mutable_teslacam="${TESLAUSB_MUTABLE_TESLACAM:-/mutable/TeslaCam}"
  snapshots_root="${TESLAUSB_SNAPSHOTS_ROOT:-/backingfiles/snapshots}"
  status_file="${TESLAUSB_ENCRYPTED_STATUS_FILE:-/mutable/teslausb/encrypted-clips-status.json}"
  envsetup="${TESLAUSB_ENVSETUP:-/root/bin/envsetup.sh}"
  disable_gadget="${TESLAUSB_DISABLE_GADGET:-/root/bin/disable_gadget.sh}"
  enable_gadget="${TESLAUSB_ENABLE_GADGET:-/root/bin/enable_gadget.sh}"
  snapshot_helper="${TESLAUSB_RAW_SNAPSHOT_HELPER:-/root/bin/make_snapshot.sh}"
  detector="${TESLAUSB_ENCRYPTED_CLIPS_DETECTOR:-/root/bin/detect_encrypted_clips.sh}"
  path_status_helper="${TESLAUSB_ENCRYPTED_PATH_STATUS_HELPER:-/root/bin/encrypted_clips_path_status.sh}"
  gadget_active_file="${TESLAUSB_GADGET_ACTIVE_FILE:-/sys/kernel/config/usb_gadget/teslausb/UDC}"
  mount_command="${TESLAUSB_MOUNT_COMMAND:-mount}"
  umount_command="${TESLAUSB_UMOUNT_COMMAND:-umount}"
  findmnt_command="${TESLAUSB_FINDMNT_COMMAND:-findmnt}"
  lock_timeout="${TESLAUSB_GADGET_LOCK_TIMEOUT:-30}"
else
  gadget_lock_dir=/run/teslausb
  cam_mount=/mnt/cam
  mutable_teslacam=/mutable/TeslaCam
  snapshots_root=/backingfiles/snapshots
  status_file=/mutable/teslausb/encrypted-clips-status.json
  envsetup=/root/bin/envsetup.sh
  disable_gadget=/root/bin/disable_gadget.sh
  enable_gadget=/root/bin/enable_gadget.sh
  snapshot_helper=/root/bin/make_snapshot.sh
  detector=/root/bin/detect_encrypted_clips.sh
  path_status_helper=/root/bin/encrypted_clips_path_status.sh
  gadget_active_file=/sys/kernel/config/usb_gadget/teslausb/UDC
  mount_command=mount
  umount_command=umount
  findmnt_command=findmnt
  lock_timeout=30
fi
readonly gadget_lock_dir cam_mount mutable_teslacam snapshots_root status_file envsetup
readonly disable_gadget enable_gadget snapshot_helper detector path_status_helper
readonly gadget_active_file mount_command umount_command findmnt_command

case "$lock_timeout" in
  '' | *[!0-9]*)
    echo "invalid gadget lock timeout: $lock_timeout" >&2
    exit 64
    ;;
esac
readonly lock_timeout

if [ -r "$envsetup" ]
then
  # shellcheck source=setup/pi/envsetup.sh
  source "$envsetup"
fi

if ! declare -F log > /dev/null
then
  function log () {
    local message
    message="$(date): $*"
    if ! printf '%s\n' "$message" >> "${LOG_FILE:-/mutable/archiveloop.log}" 2> /dev/null
    then
      printf '%s\n' "$message" >&2
    fi
  }
fi
export -f log

# Cleanup may run for minutes on a nearly full card. Defer the snapshot before
# touching USB whenever it owns the directory lock, leaving recording active.
SNAPSHOTS_ROOT="$snapshots_root"
export SNAPSHOTS_ROOT
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run/snapshot_lock.sh
source "$script_dir/snapshot_lock.sh"
snapshot_lock_status=0
acquire_snapshot_lock || snapshot_lock_status=$?
if [ "$snapshot_lock_status" -ne 0 ]
then
  if [ "$snapshot_lock_status" -eq 99 ]
  then
    log "Snapshot deferred: storage cleanup or another snapshot is busy; USB connection unchanged"
  fi
  exit "$snapshot_lock_status"
fi

invalidate_encrypted_status_file() {
  local status_dir

  status_dir=$(dirname -- "$status_file")
  if [ -L "$status_dir" ] || [ ! -d "$status_dir" ]
  then
    return 0
  fi
  # A symbolic link is already unavailable to the status API. Do not follow it
  # or remove anything at its target while handling an indeterminate check.
  if [ -L "$status_file" ]
  then
    return 0
  fi
  if [ -f "$status_file" ] && ! rm -f -- "$status_file"
  then
    log "Failed to invalidate stale encrypted-clip status"
  fi
}

[[ ! -L "$gadget_lock_dir" ]] || {
  log "Refusing symbolic-link gadget lock directory"
  exit 69
}
mkdir -p -- "$gadget_lock_dir"
chmod 0700 -- "$gadget_lock_dir"
gadget_lock_file="$gadget_lock_dir/gadget-operation.lock"
readonly gadget_lock_file
[[ ! -L "$gadget_lock_file" &&
   ( ! -e "$gadget_lock_file" || -f "$gadget_lock_file" ) ]] || {
  log "Refusing non-regular gadget operation lock"
  exit 69
}
exec 9> "$gadget_lock_file"
chmod 0600 -- "$gadget_lock_file"
if ! flock -w "$lock_timeout" 9
then
  log "Another USB gadget operation is already running; snapshot skipped"
  exit 99
fi
export TESLAUSB_GADGET_LOCK_HELD=1

mounted_by_us=false
restore_gadget=false
cleanup_guarded_snapshot () {
  local status
  local camera_still_mounted=false
  status="$1"
  trap - EXIT HUP INT TERM

  if [ "$mounted_by_us" = true ]
  then
    if ! "$umount_command" "$cam_mount" > /dev/null 2>&1
    then
      camera_still_mounted=true
      log "Failed to unmount the camera filesystem during guarded cleanup"
      if [ "$status" -eq 0 ]
      then
        status=1
      fi
    fi
  fi

  if "$findmnt_command" --mountpoint "$cam_mount" > /dev/null 2>&1
  then
    camera_still_mounted=true
    log "Camera filesystem is still mounted; leaving the USB gadget disconnected"
    if [ "$status" -eq 0 ]
    then
      status=1
    fi
  fi

  if [ "$leave_disconnected" = false ] && [ "$restore_gadget" = true ]
  then
    if [ "$camera_still_mounted" = true ]
    then
      log "Refusing to restore the USB gadget while the camera filesystem is mounted"
    elif [ -r "$gadget_active_file" ] &&
         [ -n "$(head -n 1 -- "$gadget_active_file" 2> /dev/null || true)" ]
    then
      : # The raw helper already restored USB immediately after its reflink.
    elif ! "$enable_gadget"
    then
      log "Failed to restore the USB gadget after guarded snapshot processing"
      if [ "$status" -eq 0 ]
      then
        status=1
      fi
    fi
  fi
  exit "$status"
}
trap 'cleanup_guarded_snapshot "$?"' EXIT
trap 'exit 130' HUP INT TERM

if [ -r "$gadget_active_file" ] &&
   [ -n "$(head -n 1 -- "$gadget_active_file" 2> /dev/null || true)" ]
then
  restore_gadget=true
fi
if [ "$connect_after_copy" = true ]
then
  restore_gadget=true
fi

disable_status=0
"$disable_gadget" || disable_status=$?
case "$disable_status" in
  0 | 2)
    ;;
  *)
    log "Failed to disconnect the USB gadget; snapshot skipped"
    exit "$disable_status"
    ;;
esac

if "$findmnt_command" --mountpoint "$cam_mount" > /dev/null 2>&1
then
  log "Camera filesystem was already mounted; snapshot skipped"
  exit 69
fi

if ! "$mount_command" "$cam_mount"
then
  log "Failed to mount the live camera filesystem; snapshot skipped"
  exit 1
fi
mounted_by_us=true

encrypted_clips_path="$cam_mount/TeslaCam/EncryptedClips"
encrypted_clips_detected=false
encrypted_clips_status=0
"$path_status_helper" "$encrypted_clips_path" || encrypted_clips_status=$?
case "$encrypted_clips_status" in
  0)
    encrypted_clips_detected=true
    ;;
  1)
    ;;
  *)
    invalidate_encrypted_status_file
    log "Could not safely inspect Tesla EncryptedClips; camera snapshot skipped"
    exit 75
    ;;
esac

# Publish status while the live filesystem is mounted. The detector reads only
# directory entries and never opens EncryptedClips content.
status_roots=("$cam_mount/TeslaCam" "$mutable_teslacam")
latest_snapshot=$(find "$snapshots_root" -mindepth 2 -maxdepth 2 \
  -type l -name mnt -printf '%p\n' 2> /dev/null | LC_ALL=C sort | tail -n 1)
if [ -n "$latest_snapshot" ]
then
  status_roots+=("$latest_snapshot/TeslaCam")
fi
if [ -x "$detector" ] &&
   ! "$detector" --status-file "$status_file" "${status_roots[@]}" > /dev/null
then
  log "Failed to update encrypted-clip detection status"
fi

if ! "$umount_command" "$cam_mount"
then
  # Lazy unmount can hide an active filesystem from findmnt while open handles
  # still refer to it. Require a completed unmount before exporting USB again.
  log "Failed to unmount the live camera filesystem; snapshot skipped"
  exit 1
fi
if "$findmnt_command" --mountpoint "$cam_mount" > /dev/null 2>&1
then
  log "Live camera filesystem remained mounted; snapshot skipped"
  exit 1
fi
mounted_by_us=false

if [ "$encrypted_clips_detected" = true ]
then
  log "WARNING: Tesla EncryptedClips detected; camera snapshot skipped and recordings left untouched"
  exit 75
fi

snapshot_args=()
if [ "$leave_disconnected" = false ] && [ "$restore_gadget" = true ]
then
  snapshot_args+=(--resume-gadget)
fi
if [ -n "$snapshot_mode" ]
then
  snapshot_args+=("$snapshot_mode")
fi
"$snapshot_helper" "${snapshot_args[@]}"
