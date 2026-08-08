#!/bin/bash -eu

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname -- "$TEST_DIR")
readonly REPO_ROOT
REPAIR_SCRIPT="$REPO_ROOT/run/repair_gadget.sh"
readonly REPAIR_SCRIPT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP

cleanup() {
  if [[ -n "${first_pid:-}" ]]
  then
    kill "$first_pid" 2> /dev/null || true
    wait "$first_pid" 2> /dev/null || true
  fi
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  local fixture="$1"

  mkdir -p "$fixture/backingfiles" "$fixture/configfs/usb_gadget" \
    "$fixture/udc/dwc2-test" "$fixture/run" "$fixture/bin"
  printf 'camera image\n' > "$fixture/backingfiles/cam_disk.bin"
  printf 'music image\n' > "$fixture/backingfiles/music_disk.bin"

  # shellcheck disable=SC2016 # These lines form isolated fixture scripts.
  printf '%s\n' \
    '#!/bin/bash' \
    'set -eu' \
    'printf "disable\n" >> "$FAKE_CALL_LOG"' \
    'if [[ ! -d "$FAKE_GADGET_ROOT" ]]; then exit 2; fi' \
    'find "$FAKE_GADGET_ROOT" -mindepth 1 -delete' \
    'rmdir "$FAKE_GADGET_ROOT"' > "$fixture/bin/disable"

  # shellcheck disable=SC2016 # These lines form isolated fixture scripts.
  printf '%s\n' \
    '#!/bin/bash' \
    'set -eu' \
    'printf "enable\n" >> "$FAKE_CALL_LOG"' \
    'function_root="$FAKE_GADGET_ROOT/functions/mass_storage.0"' \
    'config_root="$FAKE_GADGET_ROOT/configs/c.1"' \
    'mkdir -p "$function_root/lun.0" "$function_root/lun.1" "$config_root"' \
    'printf "%s\n" "$FAKE_BACKINGFILES_ROOT/cam_disk.bin" > "$function_root/lun.0/file"' \
    'printf "%s\n" "$FAKE_BACKINGFILES_ROOT/music_disk.bin" > "$function_root/lun.1/file"' \
    'ln -s "$function_root" "$config_root/mass_storage.0"' \
    'printf "dwc2-test\n" > "$FAKE_GADGET_ROOT/UDC"' > "$fixture/bin/enable"
  chmod +x "$fixture/bin/disable" "$fixture/bin/enable"
}

run_repair() {
  local fixture="$1"
  shift

  TESLAUSB_REPAIR_ALLOW_TEST_OVERRIDES=1 \
  TESLAUSB_BACKINGFILES_ROOT="$fixture/backingfiles" \
  TESLAUSB_REPAIR_RUN_DIR="$fixture/run" \
  TESLAUSB_ENABLE_GADGET="$fixture/bin/enable" \
  TESLAUSB_DISABLE_GADGET="$fixture/bin/disable" \
  TESLAUSB_UDC_CLASS="$fixture/udc" \
  TESLAUSB_CONFIGFS_ROOT="$fixture/configfs" \
  FAKE_BACKINGFILES_ROOT="$fixture/backingfiles" \
  FAKE_GADGET_ROOT="$fixture/configfs/usb_gadget/teslausb" \
  FAKE_CALL_LOG="$fixture/calls" \
  FAKE_LOCK_HELD="${FAKE_LOCK_HELD:-}" \
    bash "$REPAIR_SCRIPT" "$@"
}

status=0
bash "$REPAIR_SCRIPT" unexpected-argument > /dev/null 2>&1 || status=$?
[[ "$status" -eq 64 ]] || fail "an unexpected argument returned $status instead of 64"
grep -F -- 'timeout --foreground --kill-after=5s' "$REPAIR_SCRIPT" > /dev/null \
  || fail 'gadget repair operations are not time bounded'
for helper in "$REPO_ROOT/run/enable_gadget.sh" "$REPO_ROOT/run/disable_gadget.sh"
do
  helper_name=${helper##*/}
  grep -F 'gadget-operation.lock' "$helper" > /dev/null \
    || fail "$helper_name does not share the gadget operation lock"
done

success_fixture="$TEST_TMP/success"
make_fixture "$success_fixture"
output=$(run_repair "$success_fixture" 2>&1) || fail 'a healthy fixture did not repair successfully'
[[ "$output" == *'USB gadget rebuilt and verified with 2 drive(s).'* ]] \
  || fail 'successful repair did not report its verified LUN count'
[[ "$(<"$success_fixture/configfs/usb_gadget/teslausb/UDC")" == dwc2-test ]] \
  || fail 'successful repair did not bind the expected UDC'
[[ "$(<"$success_fixture/calls")" == $'disable\nenable' ]] \
  || fail 'successful repair did not perform one guarded rebuild'

status=0
output=$(run_repair "$success_fixture" 2>&1) || status=$?
[[ "$status" -eq 75 ]] || fail "a repeated repair returned $status instead of 75"
[[ "$output" == *'rate limited; try again in '* ]] \
  || fail 'a repeated repair did not explain its rate limit'
[[ "$(<"$success_fixture/calls")" == $'disable\nenable' ]] \
  || fail 'a rate-limited request changed the gadget'

preflight_fixture="$TEST_TMP/preflight"
make_fixture "$preflight_fixture"
rm -f -- "$preflight_fixture/backingfiles/cam_disk.bin"
status=0
output=$(run_repair "$preflight_fixture" 2>&1) || status=$?
[[ "$status" -eq 69 ]] || fail "missing camera image returned $status instead of 69"
[[ "$output" == *'camera backing image is missing'* ]] \
  || fail 'missing camera image did not produce a useful preflight error'
[[ ! -e "$preflight_fixture/calls" ]] \
  || fail 'failed preflight invoked a gadget helper'

symlink_fixture="$TEST_TMP/symlink-image"
make_fixture "$symlink_fixture"
printf 'outside camera image\n' > "$symlink_fixture/outside-camera.bin"
rm -f -- "$symlink_fixture/backingfiles/cam_disk.bin"
if ln -s "$symlink_fixture/outside-camera.bin" \
     "$symlink_fixture/backingfiles/cam_disk.bin" 2> /dev/null
then
  status=0
  output=$(run_repair "$symlink_fixture" 2>&1) || status=$?
  [[ "$status" -eq 69 ]] || \
    fail "symbolic-link camera image returned $status instead of 69"
  [[ "$output" == *'not a readable, non-empty regular file'* ]] || \
    fail 'symbolic-link camera image did not produce a useful preflight error'
  [[ ! -e "$symlink_fixture/calls" ]] || \
    fail 'symbolic-link image preflight invoked a gadget helper'
else
  printf 'SKIP: local filesystem cannot create symbolic links\n' >&2
fi

verify_fixture="$TEST_TMP/verify"
make_fixture "$verify_fixture"
# shellcheck disable=SC2016 # This line forms an isolated fixture script.
printf '%s\n' '#!/bin/bash' 'set -eu' 'printf "enable\n" >> "$FAKE_CALL_LOG"' \
  'mkdir -p "$FAKE_GADGET_ROOT"' > "$verify_fixture/bin/enable"
chmod +x "$verify_fixture/bin/enable"
status=0
output=$(run_repair "$verify_fixture" 2>&1) || status=$?
[[ "$status" -eq 70 ]] || fail "failed post-repair verification returned $status instead of 70"
[[ "$output" == *'verification failed; it has been left disconnected'* ]] \
  || fail 'verification failure did not explain the safe disconnected state'
[[ ! -d "$verify_fixture/configfs/usb_gadget/teslausb" ]] \
  || fail 'verification failure left a partial gadget connected'

lock_fixture="$TEST_TMP/lock"
make_fixture "$lock_fixture"
mv "$lock_fixture/bin/disable" "$lock_fixture/bin/disable-real"
# shellcheck disable=SC2016 # These lines form an isolated fixture script.
printf '%s\n' \
  '#!/bin/bash' \
  'set -eu' \
  'touch "$FAKE_LOCK_HELD"' \
  'sleep 2' \
  'exec "$(dirname "$0")/disable-real"' > "$lock_fixture/bin/disable"
chmod +x "$lock_fixture/bin/disable"
FAKE_LOCK_HELD="$lock_fixture/lock-held" run_repair "$lock_fixture" \
  > "$lock_fixture/first.out" 2>&1 &
first_pid=$!
for _ in {1..100}
do
  [[ -e "$lock_fixture/lock-held" ]] && break
  sleep 0.05
done
[[ -e "$lock_fixture/lock-held" ]] || fail 'lock fixture did not start its first repair'
status=0
output=$(FAKE_LOCK_HELD="$lock_fixture/lock-held" run_repair "$lock_fixture" 2>&1) || status=$?
[[ "$status" -eq 75 ]] || fail "concurrent repair returned $status instead of 75"
[[ "$output" == *'already running'* ]] || fail 'concurrent repair did not explain lock contention'
wait "$first_pid" || fail 'the lock-holding repair did not finish successfully'
first_pid=

printf 'gadget repair tests passed\n'
