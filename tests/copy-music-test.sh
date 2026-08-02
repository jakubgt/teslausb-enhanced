#!/bin/bash -eu

set -eu

BASH_BIN="${BASH_BIN:-$BASH}"
readonly BASH_BIN

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
trap 'rm -rf "$TEST_TMP"' EXIT

fakebin="$TEST_TMP/bin"
src="$TEST_TMP/musicarchive"
dst="$TEST_TMP/music"
calls="$TEST_TMP/rsync.calls"
messages="$TEST_TMP/messages.log"
mkdir -p "$fakebin" "$src" "$dst"

printf '%s\n' '#!/bin/sh' 'exit 0' > "$fakebin/findmnt"
# These expansions are intentionally deferred to the generated rsync stub.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$RSYNC_CALLS"' \
  'printf "%s\n" "Number of files: 0 (reg: 0)"' \
  'printf "%s\n" "Number of regular files transferred: 0"' \
  'printf "%s\n" "Number of deleted files: 0 (reg: 0)"' \
  'exit "${FAKE_RSYNC_STATUS:-0}"' > "$fakebin/rsync"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TEST_TMP/archive-is-reachable"
chmod +x "$fakebin/findmnt" "$fakebin/rsync" "$TEST_TMP/archive-is-reachable"

function log {
  printf '%s\n' "$*" >> "$MESSAGE_LOG"
}
export -f log
export MESSAGE_LOG="$messages"
export RSYNC_CALLS="$calls"

MUSIC_ARCHIVE_MOUNT="$src" \
MUSIC_MOUNT="$dst" \
MUSIC_SYNC_LOG="$TEST_TMP/rsync.log" \
ARCHIVE_IS_REACHABLE="$TEST_TMP/archive-is-reachable" \
ARCHIVE_SERVER=example.invalid \
PATH="$fakebin:$PATH" \
"$BASH_BIN" -eu "$REPO_ROOT/run/copy-music.sh"

[ "$(wc -l < "$calls")" -eq 1 ] || {
  echo "FAIL: shared music sync did not invoke rsync exactly once" >&2
  exit 1
}
grep -q '^Copied 0 music file(s)' "$messages" || {
  echo "FAIL: shared music sync did not report completion" >&2
  exit 1
}

status=0
FAKE_RSYNC_STATUS=23 \
MUSIC_ARCHIVE_MOUNT="$src" \
MUSIC_MOUNT="$dst" \
MUSIC_SYNC_LOG="$TEST_TMP/rsync-failure.log" \
ARCHIVE_IS_REACHABLE="$TEST_TMP/archive-is-reachable" \
ARCHIVE_SERVER=example.invalid \
PATH="$fakebin:$PATH" \
"$BASH_BIN" -eu "$REPO_ROOT/run/copy-music.sh" || status=$?

[ "$status" -eq 23 ] || {
  echo "FAIL: expected rsync status 23, got $status" >&2
  exit 1
}
grep -q '^rsync failed with error 23$' "$messages" || {
  echo "FAIL: shared music sync did not log the rsync status" >&2
  exit 1
}

echo "copy music test passed"
