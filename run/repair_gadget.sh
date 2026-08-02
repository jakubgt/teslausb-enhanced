#!/bin/bash -eu

# Rebuild the USB mass-storage gadget on explicit operator request. This is a
# deliberately manual recovery path: nothing schedules or invokes it
# automatically.

set -o pipefail

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
readonly PATH
export PATH
umask 077

if (( $# != 0 ))
then
  printf 'repair_gadget.sh does not accept arguments.\n' >&2
  exit 64
fi

readonly default_backingfiles_root=/backingfiles
readonly default_run_dir=/run/teslausb
readonly default_enable_gadget=/root/bin/enable_gadget.sh
readonly default_disable_gadget=/root/bin/disable_gadget.sh
readonly default_udc_class=/sys/class/udc

# Test overrides are intentionally opt-in. The sudo dispatcher uses a reset
# environment and never sets this flag, so web requests cannot redirect a root
# repair into caller-controlled paths.
if [[ "${TESLAUSB_REPAIR_ALLOW_TEST_OVERRIDES:-}" == 1 ]]
then
  backingfiles_root="${TESLAUSB_BACKINGFILES_ROOT:-$default_backingfiles_root}"
  repair_run_dir="${TESLAUSB_REPAIR_RUN_DIR:-$default_run_dir}"
  enable_gadget="${TESLAUSB_ENABLE_GADGET:-$default_enable_gadget}"
  disable_gadget="${TESLAUSB_DISABLE_GADGET:-$default_disable_gadget}"
  udc_class="${TESLAUSB_UDC_CLASS:-$default_udc_class}"
  configfs_root="${TESLAUSB_CONFIGFS_ROOT:-}"
else
  backingfiles_root=$default_backingfiles_root
  repair_run_dir=$default_run_dir
  enable_gadget=$default_enable_gadget
  disable_gadget=$default_disable_gadget
  udc_class=$default_udc_class
  configfs_root=
fi
readonly backingfiles_root repair_run_dir enable_gadget disable_gadget udc_class

readonly cooldown_seconds=60
readonly operation_timeout_seconds=15
readonly lock_file="$repair_run_dir/gadget-operation.lock"
readonly attempt_file="$repair_run_dir/gadget-repair.last-attempt"

repair_log() {
  printf '%s\n' "$*" >&2
  if command -v logger > /dev/null 2>&1
  then
    logger --tag teslausb-gadget-repair -- "$*" || true
  fi
}

temporary_failure() {
  repair_log "$*"
  exit 75
}

repair_failure() {
  repair_log "$*"
  exit 70
}

preflight_failure() {
  repair_log "$*"
  exit 69
}

if (( EUID != 0 )) && [[ "${TESLAUSB_REPAIR_ALLOW_TEST_OVERRIDES:-}" != 1 ]]
then
  preflight_failure 'USB gadget repair must run as root.'
fi

if [[ -L "$repair_run_dir" ]]
then
  preflight_failure "Repair state directory must not be a symbolic link: $repair_run_dir"
fi
mkdir -p -- "$repair_run_dir"
chmod 0700 -- "$repair_run_dir"

command -v flock > /dev/null 2>&1 || preflight_failure 'flock is required for guarded USB gadget repair.'
command -v timeout > /dev/null 2>&1 || preflight_failure 'timeout is required for bounded USB gadget repair.'
if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]
then
  preflight_failure "Repair lock must be a regular file: $lock_file"
fi
exec 9> "$lock_file"
chmod 0600 -- "$lock_file"
if ! flock -n 9
then
  temporary_failure 'Another USB gadget operation is already running.'
fi

read -r uptime_seconds _ < /proc/uptime
uptime_seconds=${uptime_seconds%%.*}
if [[ ! "$uptime_seconds" =~ ^[0-9]+$ ]]
then
  preflight_failure 'Unable to read the system uptime for repair rate limiting.'
fi

if [[ -f "$attempt_file" && ! -L "$attempt_file" ]]
then
  last_attempt=$(<"$attempt_file")
  if [[ "$last_attempt" =~ ^[0-9]+$ ]] &&
     (( uptime_seconds >= last_attempt && uptime_seconds - last_attempt < cooldown_seconds ))
  then
    retry_after=$((cooldown_seconds - (uptime_seconds - last_attempt)))
    temporary_failure "USB gadget repair is rate limited; try again in $retry_after seconds."
  fi
fi

[[ -x "$enable_gadget" ]] || preflight_failure "USB gadget enable helper is unavailable: $enable_gadget"
[[ -x "$disable_gadget" ]] || preflight_failure "USB gadget disable helper is unavailable: $disable_gadget"

if [[ -z "$configfs_root" ]]
then
  configfs_root=$(findmnt -o TARGET -n configfs 2> /dev/null || true)
fi
if [[ -z "$configfs_root" || ! -d "$configfs_root" ]]
then
  preflight_failure 'configfs is not mounted.'
fi
readonly configfs_root
readonly gadget_root="$configfs_root/usb_gadget/teslausb"

if [[ ! -d "$udc_class" ]] ||
   ! find "$udc_class" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
then
  preflight_failure 'No USB device controller is available.'
fi

declare -a image_paths=()
for image_name in cam_disk.bin music_disk.bin lightshow_disk.bin boombox_disk.bin
do
  image_path="$backingfiles_root/$image_name"
  if [[ -e "$image_path" || -L "$image_path" ]]
  then
    if [[ -L "$image_path" || ! -f "$image_path" || ! -r "$image_path" ||
          ! -s "$image_path" ]]
    then
      preflight_failure "Backing image is not a readable, non-empty regular file: $image_path"
    fi
    image_paths+=("$image_path")
  fi
done
if [[ -L "$backingfiles_root/cam_disk.bin" ||
      ! -f "$backingfiles_root/cam_disk.bin" || ! -r "$backingfiles_root/cam_disk.bin" ||
      ! -s "$backingfiles_root/cam_disk.bin" ]]
then
  preflight_failure 'The camera backing image is missing, unreadable, or empty.'
fi

# Count only attempts which reached the point where the gadget can actually be
# changed. A corrected preflight problem can therefore be retried immediately.
attempt_tmp=$(mktemp "$repair_run_dir/.gadget-repair-attempt.XXXXXX")
printf '%s\n' "$uptime_seconds" > "$attempt_tmp"
chmod 0600 "$attempt_tmp"
mv -fT -- "$attempt_tmp" "$attempt_file"

verify_repaired_gadget() {
  local actual_path
  local bound_udc
  local expected_path
  local index
  local lun_file

  [[ -d "$gadget_root/functions/mass_storage.0" ]] || return 1
  [[ -L "$gadget_root/configs/c.1/mass_storage.0" ]] || return 1
  [[ -r "$gadget_root/UDC" ]] || return 1
  bound_udc=$(<"$gadget_root/UDC")
  [[ -n "$bound_udc" ]] || return 1
  [[ -e "$udc_class/$bound_udc" || -L "$udc_class/$bound_udc" ]] || return 1

  for index in "${!image_paths[@]}"
  do
    lun_file="$gadget_root/functions/mass_storage.0/lun.$index/file"
    [[ -r "$lun_file" ]] || return 1
    actual_path=$(<"$lun_file")
    expected_path=$(readlink -f -- "${image_paths[$index]}") || return 1
    actual_path=$(readlink -f -- "$actual_path") || return 1
    [[ "$actual_path" == "$expected_path" ]] || return 1
  done
}

repair_log 'Manual USB gadget repair started.'
if ! timeout --foreground --kill-after=5s "${operation_timeout_seconds}s" sync
then
  repair_failure 'Timed out while flushing pending writes; the USB gadget was not changed.'
fi

disable_status=0
TESLAUSB_GADGET_LOCK_HELD=1 timeout --foreground --kill-after=5s "${operation_timeout_seconds}s" \
  "$disable_gadget" || disable_status=$?
if (( disable_status != 0 && disable_status != 2 ))
then
  repair_failure "Unable to release the existing USB gadget (exit $disable_status)."
fi
if [[ -d "$gadget_root" ]]
then
  repair_failure 'The existing USB gadget did not release cleanly.'
fi

if ! TESLAUSB_GADGET_LOCK_HELD=1 \
     timeout --foreground --kill-after=5s "${operation_timeout_seconds}s" \
     "$enable_gadget"
then
  TESLAUSB_GADGET_LOCK_HELD=1 \
    timeout --foreground --kill-after=5s "${operation_timeout_seconds}s" \
    "$disable_gadget" > /dev/null 2>&1 || true
  repair_failure 'Unable to rebuild the USB gadget; it has been left disconnected.'
fi

if ! verify_repaired_gadget
then
  TESLAUSB_GADGET_LOCK_HELD=1 \
    timeout --foreground --kill-after=5s "${operation_timeout_seconds}s" \
    "$disable_gadget" > /dev/null 2>&1 || true
  repair_failure 'USB gadget verification failed; it has been left disconnected.'
fi

repair_log "Manual USB gadget repair completed and verified with ${#image_paths[@]} drive(s)."
printf 'USB gadget rebuilt and verified with %d drive(s).\n' "${#image_paths[@]}"
