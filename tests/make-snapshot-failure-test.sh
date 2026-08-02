#!/bin/bash -eu

set -eu

BASH_BIN="${BASH_BIN:-$BASH}"
readonly BASH_BIN

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
trap 'rm -rf "$TEST_TMP"' EXIT

backingfiles="$TEST_TMP/backingfiles"
test_log="$TEST_TMP/snapshot.log"
late_command_marker="$TEST_TMP/losetup-was-called"
mkdir -p "$backingfiles"
touch "$backingfiles/cam_disk.bin"

# Export lightweight stubs into the child Bash. cp fails at the first critical
# snapshot operation; no later command may run after that failure.
function cp {
  return 42
}

function losetup_find_show {
  touch "$LATE_COMMAND_MARKER"
  printf '%s\n' /dev/loop-test
}

function log {
  printf '%s\n' "$*" >> "$TEST_LOG"
}

export -f cp losetup_find_show log
export LATE_COMMAND_MARKER="$late_command_marker"
export TEST_LOG="$test_log"

snapshot_script="$REPO_ROOT/run/make_snapshot.sh"
status=0
FLOCKED="$snapshot_script" \
BACKINGFILES_ROOT="$backingfiles" \
SNAPSHOT_MOUNT_ROOT="$TEST_TMP/snapshot-mounts" \
"$BASH_BIN" -eu "$snapshot_script" nofsck || status=$?

[ "$status" -eq 42 ] || {
  echo "FAIL: expected snapshot failure status 42, got $status" >&2
  exit 1
}
[ ! -e "$late_command_marker" ] || {
  echo "FAIL: snapshot continued after cp failed" >&2
  exit 1
}
grep -q '^failed to take snapshot$' "$test_log" || {
  echo "FAIL: snapshot failure was not logged" >&2
  exit 1
}

echo "snapshot failure test passed"
