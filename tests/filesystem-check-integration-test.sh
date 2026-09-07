#!/bin/bash -eu

# Real caller control flow with exported fake device/checker commands. Nothing
# attaches a real loop, checks a filesystem, starts a service, or touches footage.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp=$(mktemp -d /tmp/teslausb-filesystem-integration.XXXXXX)
trap 'rm -rf -- "$test_tmp"' EXIT
export TEST_BACKING_ROOT="$test_tmp/live"
export TEST_CALLS="$test_tmp/calls"
export LOG_FILE="$test_tmp/log"
export TEST_REPO_ROOT="$repo_root"
export TEST_SNAPSHOTS_ROOT="$test_tmp/snapshot-lock"
export TEST_GADGET_RUN_DIR="$test_tmp/gadget-lock"
export TEST_CONFIGFS="$test_tmp/configfs"
export TEST_UDC_CLASS="$test_tmp/udc"
mkdir -p "$TEST_BACKING_ROOT" "$TEST_CONFIGFS/usb_gadget/teslausb" "$TEST_UDC_CLASS/fixture-controller"
touch "$TEST_BACKING_ROOT/cam_disk.bin" "$TEST_BACKING_ROOT/music_disk.bin"
touch "$TEST_CONFIGFS/usb_gadget/teslausb/UDC"
touch "$TEST_UDC_CLASS/fixture-controller/function"

for function_name in fix_errors_in_image fix_errors_in_images
do
  # Redirect only the hard-coded image directory into this test's private tree.
  eval "$(sed -n "/^function $function_name () {$/,/^}$/p" "$repo_root/run/archiveloop" |
    sed -e 's@img="/backingfiles/@img="$TEST_BACKING_ROOT/@' \
      -e 's@SNAPSHOTS_ROOT=/backingfiles/snapshots@SNAPSHOTS_ROOT="$TEST_SNAPSHOTS_ROOT"@' \
      -e 's@gadget_lock_dir=/run/teslausb@gadget_lock_dir="$TEST_GADGET_RUN_DIR"@' \
      -e 's@udc_class=/sys/class/udc@udc_class="$TEST_UDC_CLASS"@' \
      -e 's@source /root/bin/snapshot_lock.sh@source "$TEST_REPO_ROOT/run/snapshot_lock.sh"@' \
      -e 's@/root/bin/disable_gadget.sh@disable_gadget_stub@')"
done
eval "$(sed -n '/^function disconnect_usb_drives_from_host () {$/,/^}$/p' \
  "$repo_root/run/archiveloop" | sed 's@/root/bin/disable_gadget.sh@disable_gadget_stub@')"
eval "$(sed -n '/^function log_errors_on_exit {$/,/^}$/p' "$repo_root/run/archiveloop")"

function log { printf '%s\n' "$*" >> "$LOG_FILE"; }
function losetup_find_show {
  printf 'attach\n' >> "$TEST_CALLS"
  if [ "${TEST_ATTACH_STATUS:-0}" -ne 0 ]; then return "$TEST_ATTACH_STATUS"; fi
  printf '/dev/loop-test\n'
}
function losetup {
  [ "$*" = '-d /dev/loop-test' ] || return 64
  printf 'detach\n' >> "$TEST_CALLS"
  return "${TEST_DETACH_STATUS:-0}"
}
function python3 {
  [ "$*" = '/root/bin/check-filesystem.py /dev/loop-testp1' ] || return 64
  if [ "${TEST_REQUIRE_LOCKS:-0}" = 1 ]
  then
    if flock -n "$TEST_SNAPSHOTS_ROOT" true ||
       flock -n "$TEST_GADGET_RUN_DIR/gadget-operation.lock" true ||
       [ "${TESLAUSB_GADGET_LOCK_HELD:-}" != 1 ]
    then
      printf 'UNEXPECTED missing filesystem-operation lock\n' >> "$TEST_CALLS"
      return 64
    fi
  fi
  printf 'check\n' >> "$TEST_CALLS"
  printf 'fixture check output\n'
  return "${TEST_CHECK_STATUS:-0}"
}
function timestamp {
  cat
  return "${TEST_LOGGER_STATUS:-0}"
}
function disable_gadget_stub {
  printf 'disable\n' >> "$TEST_CALLS"
  return "${TEST_DISABLE_STATUS:-0}"
}
function findmnt {
  if [ "$*" = '-o TARGET -n configfs' ]
  then
    printf '%s\n' "$TEST_CONFIGFS"
  elif [ "$*" = '--kernel --raw --noheadings --output TARGET' ]
  then
    printf '%s\n' "${TEST_LIVE_MOUNTS-/}"
    return "${TEST_MOUNT_STATUS:-0}"
  else
    return 64
  fi
}
function flock {
  # Only shorten the production wait during the real-contention test. The real
  # util-linux command still opens/locks the descriptors and reports conflicts.
  if [ "${TEST_LOCK_ERROR:-0}" = 1 ] && [ "$*" = '-E 75 -w 30 9' ]
  then
    return 70
  elif [ "${TEST_FAST_LOCK_WAIT:-0}" = 1 ] && [ "$*" = '-E 75 -w 30 9' ]
  then
    command flock -E 75 -n 9
  else
    command flock "$@"
  fi
}
function clean_cam_mount { printf 'UNEXPECTED cleanup\n' >> "$TEST_CALLS"; }
function connect_usb_drives_to_host { printf 'UNEXPECTED reconnect\n' >> "$TEST_CALLS"; }
export -f log losetup_find_show losetup python3 timestamp disable_gadget_stub findmnt flock \
  clean_cam_mount connect_usb_drives_to_host fix_errors_in_image \
  fix_errors_in_images disconnect_usb_drives_from_host log_errors_on_exit

function expect_status {
  local expected="$1" actual=0
  shift
  "$@" || actual=$?
  [ "$actual" -eq "$expected" ] || {
    printf 'Expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
    exit 1
  }
}
function reset_logs { : > "$TEST_CALLS"; : > "$LOG_FILE"; }
function assert_no_success {
  if grep -Eq 'Finished verified|Finished fsck' "$LOG_FILE" || grep -q '^UNEXPECTED' "$TEST_CALLS"
  then
    echo 'Failed filesystem check was ignored or logged as successful' >&2
    exit 1
  fi
}

# A successful logger cannot hide a failed checker, even with pipefail/errexit.
for check_status in 69 137
do
  reset_logs
  TEST_CHECK_STATUS="$check_status" expect_status 78 bash -euo pipefail -c \
    'fix_errors_in_image "$TEST_BACKING_ROOT/cam_disk.bin"; clean_cam_mount boot; connect_usb_drives_to_host'
  [ "$(<"$TEST_CALLS")" = $'attach\ncheck\ndetach' ]
  assert_no_success
done

# The successful path is reported only after checking and detaching both pass.
reset_logs
expect_status 0 bash -euo pipefail -c 'fix_errors_in_image "$TEST_BACKING_ROOT/cam_disk.bin"'
[ "$(<"$TEST_CALLS")" = $'attach\ncheck\ndetach' ]
grep -q '^Finished verified filesystem check' "$LOG_FILE"

for failure in logger detach attach
do
  reset_logs
  case "$failure" in
    logger) TEST_LOGGER_STATUS=74 expect_status 78 bash -euo pipefail -c 'fix_errors_in_image fixture' ;;
    detach) TEST_DETACH_STATUS=1 expect_status 78 bash -euo pipefail -c 'fix_errors_in_image fixture' ;;
    attach) TEST_ATTACH_STATUS=1 expect_status 78 bash -euo pipefail -c 'fix_errors_in_image fixture' ;;
  esac
  assert_no_success
done

# Aggregate checking must stop at the first failed image even in a conditional
# caller, where Bash's errexit is disabled throughout the function body.
reset_logs
TEST_CHECK_STATUS=69 TEST_REQUIRE_LOCKS=1 expect_status 78 bash -euo pipefail -c \
  'if fix_errors_in_images; then clean_cam_mount boot; else exit "$?"; fi'
[ "$(<"$TEST_CALLS")" = $'disable\nattach\ncheck\ndetach' ]
assert_no_success

# Disconnect/recheck is called from conditional archive workflows. Failure must
# exit the process, not fall through to mount/cleanup/reconnect in the caller.
reset_logs
TEST_CHECK_STATUS=69 TEST_REQUIRE_LOCKS=1 expect_status 78 bash -euo pipefail -c \
  'if disconnect_usb_drives_from_host; then clean_cam_mount boot; fi; connect_usb_drives_to_host'
[ "$(<"$TEST_CALLS")" = $'disable\nattach\ncheck\ndetach' ]
assert_no_success

# Execute the actual startup sequence through its first USB connection. A live
# check failure must stop before cleanup or any retention/snapshot worker starts.
startup=$(sed -n '/^fix_errors_in_images || exit /,/^connect_usb_drives_to_host$/p' "$repo_root/run/archiveloop")
[ -n "$startup" ]
reset_logs
TEST_CHECK_STATUS=69 TEST_REQUIRE_LOCKS=1 expect_status 78 bash -euo pipefail -c "$startup"
[ "$(<"$TEST_CALLS")" = $'disable\nattach\ncheck\ndetach' ]
assert_no_success

# The operation releases both real locks on failure. A still-bound gadget or
# mounted live image must be rejected before attaching/checking any image.
flock -n "$TEST_SNAPSHOTS_ROOT" true
flock -n "$TEST_GADGET_RUN_DIR/gadget-operation.lock" true

# Normal lock contention is retryable, not a terminal filesystem failure. Keep
# the connection untouched and propagate 75 through aggregate/disconnect/startup.
exec {held_snapshot}< "$TEST_SNAPSHOTS_ROOT"
flock -n "$held_snapshot"
for caller in 'fix_errors_in_images' 'disconnect_usb_drives_from_host' "$startup"
do
  reset_logs
  expect_status 75 bash -euo pipefail -c "$caller"
  [ ! -s "$TEST_CALLS" ]
  grep -q 'Filesystem check deferred:' "$LOG_FILE"
done
exec {held_snapshot}<&-
flock -n "$TEST_SNAPSHOTS_ROOT" true

exec {held_gadget}> "$TEST_GADGET_RUN_DIR/gadget-operation.lock"
flock -n "$held_gadget"
for caller in 'fix_errors_in_images' 'disconnect_usb_drives_from_host' "$startup"
do
  reset_logs
  TEST_FAST_LOCK_WAIT=1 expect_status 75 bash -euo pipefail -c "$caller"
  [ ! -s "$TEST_CALLS" ]
  grep -q 'Filesystem check deferred:' "$LOG_FILE"
  flock -n "$TEST_SNAPSHOTS_ROOT" true
done
exec {held_gadget}>&-
flock -n "$TEST_GADGET_RUN_DIR/gadget-operation.lock" true

# Malformed inherited handles and command failures are not ordinary contention.
reset_logs
TESLAUSB_SNAPSHOT_LOCK_FD=9 expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ ! -s "$TEST_CALLS" ]
reset_logs
TEST_LOCK_ERROR=1 expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ ! -s "$TEST_CALLS" ]

for live_mount in /mnt/cam /mnt/music /mnt/lightshow /mnt/boombox /mnt/cam/child
do
  reset_logs
  TEST_LIVE_MOUNTS="$live_mount" expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
  [ "$(<"$TEST_CALLS")" = disable ]
done
reset_logs
TEST_MOUNT_STATUS=1 expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ "$(<"$TEST_CALLS")" = disable ]
reset_logs
TEST_LIVE_MOUNTS= expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ "$(<"$TEST_CALLS")" = disable ]
reset_logs
TEST_DISABLE_STATUS=1 expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ "$(<"$TEST_CALLS")" = disable ]
printf 'fixture-controller\n' > "$TEST_CONFIGFS/usb_gadget/teslausb/UDC"
reset_logs
expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ "$(<"$TEST_CALLS")" = disable ]

# Preserve the terminal status through archiveloop's outer flock/log wrapper,
# because systemd applies RestartPreventExitStatus to that main process.
runtime_wrapper=$(sed -n '/^if \[ "${FLOCKED:-}" != "\$0" \]/,/^fi$/p' "$repo_root/run/archiveloop")
[ -n "$runtime_wrapper" ]
export TEST_RUNTIME_WRAPPER="$runtime_wrapper"
for wrapper_status in 75 78
do
  reset_logs
  TEST_WRAPPER_STATUS="$wrapper_status" expect_status "$wrapper_status" bash -euo pipefail -c '
    unset FLOCKED
    function flock { return "$TEST_WRAPPER_STATUS"; }
    function journalctl { return 0; }
    eval "$TEST_RUNTIME_WRAPPER"
  '
  grep -q "archiveloop exited with code $wrapper_status" "$LOG_FILE"
done
: > "$TEST_CONFIGFS/usb_gadget/teslausb/UDC"
printf 'legacy-mass-storage\n' > "$TEST_UDC_CLASS/fixture-controller/function"
reset_logs
expect_status 78 bash -euo pipefail -c 'fix_errors_in_images'
[ "$(<"$TEST_CALLS")" = disable ]
: > "$TEST_UDC_CLASS/fixture-controller/function"

# A later mount step with an already-disconnected gadget must not recheck images
# that the archive workflow has already mounted. Startup still checks them.
reset_logs
TEST_DISABLE_STATUS=2 TEST_LIVE_MOUNTS=/mnt/cam expect_status 0 \
  bash -euo pipefail -c 'disconnect_usb_drives_from_host'
[ "$(<"$TEST_CALLS")" = disable ]

# Failed checking of an independent snapshot copy retains its incomplete image,
# detaches its loop, and never reaches autofs/indexing. Real flock remains in use.
function cp { printf 'reflink\n' >> "$TEST_CALLS"; touch "${@: -1}"; }
function mount { return 0; }
function systemctl { printf 'UNEXPECTED autofs\n' >> "$TEST_CALLS"; return 0; }
function getconf { printf '64\n'; }
export -f cp mount systemctl getconf
for check_status in 69 137
do
  reset_logs
  snapshot_root="$test_tmp/snapshot-$check_status"
  mkdir -p "$snapshot_root"
  touch "$snapshot_root/cam_disk.bin"
  TEST_CHECK_STATUS="$check_status" BACKINGFILES_ROOT="$snapshot_root" \
    SNAPSHOT_MOUNT_ROOT="$test_tmp/snapshot-mounts" expect_status 69 \
    bash "$repo_root/run/make_snapshot.sh" fsck
  [ "$(<"$TEST_CALLS")" = $'reflink\nattach\ncheck\ndetach' ]
  [ -f "$snapshot_root/snapshots/snap-000000/snap.bin" ]
  [ ! -e "$snapshot_root/snapshots/snap-000000/snap.bin.toc" ]
  [ ! -e "$snapshot_root/snapshots/snap-000000/mnt" ]
  grep -q 'preserving incomplete snapshot without indexing' "$LOG_FILE"
  assert_no_success
done

grep -q '^RestartPreventExitStatus=78$' "$repo_root/setup/pi/configure.sh"
grep -Fq '"RestartPreventExitStatus=78\n"' "$repo_root/tools/card-repair/card_install.py"
grep -Fq 'copy_script run/check-filesystem.py /root/bin' "$repo_root/setup/pi/setup-teslausb"
echo 'Filesystem-check caller integration tests passed'
