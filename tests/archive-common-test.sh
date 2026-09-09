#!/bin/bash -eu

set -o pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname -- "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export ARCHIVE_STATE_DIR="$TEST_TMP/state"
export ARCHIVE_STATUS_FILE="$ARCHIVE_STATE_DIR/archive-status.json"
export ARCHIVE_RETRY_STATE_FILE="$ARCHIVE_STATE_DIR/archive-retry.state"
# shellcheck source=run/archive-common.sh
source "$REPO_ROOT/run/archive-common.sh"

source_root="$TEST_TMP/source"
destination_root="$TEST_TMP/destination"
mkdir -p "$source_root/nested" "$destination_root/nested"
printf 'alpha\n' > "$source_root/one.txt"
printf 'beta\n' > "$source_root/nested/two.txt"
printf '%s\n' one.txt nested/two.txt > "$TEST_TMP/files.txt"

manifest="$TEST_TMP/archive.tsv"
archive_manifest_create "$source_root" "$TEST_TMP/files.txt" "$manifest"
read -r files bytes < <(archive_manifest_stats "$manifest")
[ "$files" -eq 2 ] || fail "manifest file count is $files"
[ "$bytes" -eq 11 ] || fail "manifest byte count is $bytes"
manifest_name=$(archive_manifest_name "$manifest" 1)
[[ "$manifest_name" =~ ^archive-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{64}-1\.tsv$ ]] \
  || fail "manifest name is not content-addressed: $manifest_name"

cp -- "$source_root/one.txt" "$destination_root/one.txt"
cp -- "$source_root/nested/two.txt" "$destination_root/nested/two.txt"
archive_manifest_verify_local "$destination_root" "$manifest" \
  || fail 'matching destination did not verify'

symlink_destination="$TEST_TMP/symlink-destination"
mkdir -p "$symlink_destination/nested"
ln -s "$destination_root/one.txt" "$symlink_destination/one.txt"
cp -- "$destination_root/nested/two.txt" "$symlink_destination/nested/two.txt"
if archive_manifest_verify_local "$symlink_destination" "$manifest"
then
  fail 'destination verification followed a symbolic link'
fi

printf 'corrupt\n' > "$destination_root/one.txt"
if archive_manifest_verify_local "$destination_root" "$manifest"
then
  fail 'corrupt destination passed verification'
fi
[ -f "$source_root/one.txt" ] || fail 'source was removed before verification'

cp -- "$source_root/one.txt" "$destination_root/one.txt"
archive_manifest_verify_local "$destination_root" "$manifest" \
  || fail 'restored destination did not verify'
archive_manifest_publish_local "$destination_root" "$manifest" test-manifest.tsv
[ -f "$destination_root/.teslausb-manifests/test-manifest.tsv" ] \
  || fail 'integrity manifest was not published'
block_source_removal() {
  return 1
}
if archive_manifest_remove_sources "$source_root" "$manifest" block_source_removal
then
  fail 'a failing pre-remove safety guard was ignored'
fi
[ -f "$source_root/one.txt" ] || fail 'pre-remove guard did not retain the source'
[ -f "$source_root/nested/two.txt" ] || fail 'pre-remove guard did not retain the nested source'
archive_manifest_remove_sources "$source_root" "$manifest"
[ ! -e "$source_root/one.txt" ] || fail 'verified source was not removed'
[ ! -e "$source_root/nested/two.txt" ] || fail 'verified nested source was not removed'

race_source="$TEST_TMP/race-source"
mkdir -p "$race_source"
printf 'original recording\n' > "$race_source/clip.mp4"
printf 'clip.mp4\n' > "$TEST_TMP/race-files.txt"
race_manifest="$TEST_TMP/race-manifest.tsv"
archive_manifest_create "$race_source" "$TEST_TMP/race-files.txt" "$race_manifest"
# Simulate the source being replaced after the destination was verified but
# immediately before the cleanup phase.
printf 'replacement recording that must survive\n' > "$race_source/clip.mp4"
if archive_manifest_remove_sources "$race_source" "$race_manifest"
then
  fail 'source replacement was deleted using a stale integrity manifest'
fi
[ -f "$race_source/clip.mp4" ] || fail 'replacement source did not survive cleanup'
[ "$(<"$race_source/clip.mp4")" = 'replacement recording that must survive' ] \
  || fail 'replacement source content changed during cleanup'

link_source="$TEST_TMP/link-source"
link_target="$TEST_TMP/link-target"
mkdir -p "$link_source"
printf 'snapshot recording\n' > "$link_target"
ln -s "$link_target" "$link_source/clip.mp4"
printf 'clip.mp4\n' > "$TEST_TMP/link-files.txt"
link_manifest="$TEST_TMP/link-manifest.tsv"
archive_manifest_create "$link_source" "$TEST_TMP/link-files.txt" "$link_manifest"
archive_manifest_verify_sources "$link_source" "$link_manifest" \
  || fail 'snapshot source link did not verify'
printf 'changed snapshot recording\n' > "$link_target"
if archive_manifest_verify_sources "$link_source" "$link_manifest"
then
  fail 'retargeted snapshot contents passed source verification'
fi

printf '../escape\n' > "$TEST_TMP/unsafe-files.txt"
if archive_manifest_create "$destination_root" "$TEST_TMP/unsafe-files.txt" "$TEST_TMP/unsafe.tsv"
then
  fail 'unsafe relative path was accepted'
fi

message=$'quote " slash \\ and\nnewline'
archive_status_write success '2026-08-02T00:00:00Z' '2026-08-02T00:00:01Z' \
  3 400 2 300 "$message"
python3 - "$ARCHIVE_STATUS_FILE" "$message" <<'PY'
import json
import pathlib
import sys

status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert set(status) == {
    "schema_version",
    "last_result",
    "last_started",
    "last_finished",
    "last_successful_at",
    "pending_files",
    "pending_bytes",
    "transferred_files",
    "transferred_bytes",
    "message",
}
assert status["schema_version"] == 1
assert status["last_result"] == "success"
assert status["last_successful_at"] == "2026-08-02T00:00:01Z"
assert status["pending_files"] == 3
assert status["pending_bytes"] == 400
assert status["transferred_files"] == 2
assert status["transferred_bytes"] == 300
assert status["message"] == sys.argv[2]
PY
archive_status_write running '2026-08-03T00:00:00Z' '' 3 400 0 0 'Next attempt'
archive_status_write error '2026-08-03T00:00:00Z' '2026-08-03T00:00:01Z' 3 400 0 0 'Failed attempt'
archive_status_write idle '' '2026-08-04T00:00:00Z' 0 0 0 0 'Service restarted'
python3 - "$ARCHIVE_STATUS_FILE" <<'PY'
import json
import pathlib
import sys

status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["last_result"] == "idle"
assert status["last_finished"] == "2026-08-04T00:00:00Z"
assert status["last_successful_at"] == "2026-08-02T00:00:01Z"
PY
archive_status_write success '2026-08-05T00:00:00Z' '2026-08-05T00:00:01Z' 0 0 3 400 'Verified again'
python3 - "$ARCHIVE_STATUS_FILE" <<'PY'
import json
import pathlib
import sys

status = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["last_successful_at"] == "2026-08-05T00:00:01Z"
PY
if compgen -G "$ARCHIVE_STATE_DIR/.archive-status.*" > /dev/null
then
  fail 'atomic status writer left a temporary file'
fi

counter="$TEST_TMP/retry-counter"
retry_command="$TEST_TMP/retry-command"
# shellcheck disable=SC2016 # This block writes a separate test script.
printf '%s\n' \
  '#!/bin/bash' \
  'count=0' \
  '[ ! -e "$RETRY_COUNTER" ] || read -r count < "$RETRY_COUNTER"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" > "$RETRY_COUNTER"' \
  '[ "$count" -ge "${RETRY_SUCCEED_AT:-2}" ]' > "$retry_command"
chmod +x "$retry_command"
export RETRY_COUNTER="$counter"
export RETRY_SUCCEED_AT=2
export ARCHIVE_RETRY_BASE_SECONDS=0
export ARCHIVE_RETRY_MAX_SECONDS=0
export ARCHIVE_RETRY_ATTEMPTS_PER_RUN=1

if archive_retry_run "$retry_command"
then
  fail 'first retry run unexpectedly succeeded'
fi
[ -s "$ARCHIVE_RETRY_STATE_FILE" ] || fail 'retry state was not persisted'
archive_retry_run "$retry_command" || fail 'resumed retry did not succeed'
[ "$(<"$counter")" -eq 2 ] || fail 'retry command was not resumed exactly once'
[ ! -e "$ARCHIVE_RETRY_STATE_FILE" ] || fail 'retry state was not cleared after success'

retry_link_target="$TEST_TMP/retry-link-target"
printf '30 9999999999\n' > "$retry_link_target"
ln -s "$retry_link_target" "$ARCHIVE_RETRY_STATE_FILE"
archive_retry_load
[ "$ARCHIVE_RETRY_FAILURES" -eq 0 ] || fail 'retry loader followed a state symlink'
[ "$ARCHIVE_RETRY_NOT_BEFORE" -eq 0 ] || fail 'retry loader trusted a state symlink'
rm -f -- "$ARCHIVE_RETRY_STATE_FILE"

sleep_log="$TEST_TMP/sleep-log"
fake_sleep="$TEST_TMP/fake-sleep"
# shellcheck disable=SC2016 # This block writes a separate test script.
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$1" >> "$SLEEP_LOG"' > "$fake_sleep"
chmod +x "$fake_sleep"
export SLEEP_LOG="$sleep_log"
export ARCHIVE_SLEEP_BIN="$fake_sleep"
export ARCHIVE_RETRY_MAX_SECONDS=7
archive_retry_save 1 "$(( $(date +%s) + 86400 ))"
archive_retry_run true || fail 'retry did not resume after a capped stale delay'
[ "$(<"$sleep_log")" -eq 7 ] || fail 'persisted retry delay was not capped'
unset ARCHIVE_SLEEP_BIN SLEEP_LOG

unsafe_mount="$TEST_TMP/unsafe-mount"
unsafe_target="$TEST_TMP/unsafe-target"
mkdir -p "$unsafe_mount" "$unsafe_target"
printf 'keep\n' > "$unsafe_target/sentinel"
ln -s "$unsafe_target" "$unsafe_mount/.teslausbtmp"
fake_findmnt="$TEST_TMP/fake-findmnt"
# shellcheck disable=SC2016 # This block writes a separate test script.
printf '%s\n' \
  '#!/bin/bash' \
  'if [ -n "${FAKE_MOUNT_LOSS_MARKER:-}" ] && [ -e "$FAKE_MOUNT_LOSS_MARKER" ]' \
  'then' \
  '  printf "//other/share cifs 0:99\\n"' \
  'else' \
  '  printf "%s\\n" "${FAKE_MOUNT_IDENTITY:-//archive/share cifs 0:42}"' \
  'fi' > "$fake_findmnt"
chmod +x "$fake_findmnt"
function log { :; }
export -f log
status=0
ARCHIVE_COMMON_SH="$REPO_ROOT/run/archive-common.sh" \
ARCHIVE_MOUNT="$unsafe_mount" \
ARCHIVE_SERVER=example.invalid \
ARCHIVE_FINDMNT_BIN="$fake_findmnt" \
ARCHIVE_ERROR_LOG="$TEST_TMP/unsafe-temp-error.log" \
  bash "$REPO_ROOT/run/archive-rsync-local.sh" || status=$?
[ "$status" -eq 73 ] || fail "unsafe archive temp directory returned $status"
[ -L "$unsafe_mount/.teslausbtmp" ] || fail 'unsafe archive temp symlink was altered'
[ -f "$unsafe_target/sentinel" ] || fail 'unsafe archive temp target was altered'

if command -v rsync > /dev/null
then
  transfer_source="$TEST_TMP/transfer-source"
  transfer_destination="$TEST_TMP/transfer-destination"
  mkdir -p "$transfer_source" "$transfer_destination"
  printf 'verified transfer\n' > "$transfer_source/clip.txt"
  printf 'clip.txt\n' > "$TEST_TMP/transfer-files.txt"
  mkdir -p "$transfer_destination/.teslausbtmp"
  printf 'another transfer\n' > "$transfer_destination/.teslausbtmp/sibling"
  reachable="$TEST_TMP/archive-is-reachable"
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$reachable"
  chmod +x "$reachable"
  ARCHIVE_COMMON_SH="$REPO_ROOT/run/archive-common.sh" \
  ARCHIVE_MOUNT="$transfer_destination" \
  ARCHIVE_SERVER=example.invalid \
  ARCHIVE_FINDMNT_BIN="$fake_findmnt" \
  ARCHIVE_IS_REACHABLE="$reachable" \
  ARCHIVE_ERROR_LOG="$TEST_TMP/transfer-error.log" \
    bash "$REPO_ROOT/run/archive-rsync-local.sh" \
      "$transfer_source" "$TEST_TMP/transfer-files.txt"
  [ ! -e "$transfer_source/clip.txt" ] || fail 'local backend retained a verified source'
  [ "$(<"$transfer_destination/clip.txt")" = 'verified transfer' ] \
    || fail 'local backend destination content differs'
  [ "$(<"$transfer_destination/.teslausbtmp/sibling")" = 'another transfer' ] \
    || fail 'local backend removed another transfer temporary file'
  if compgen -G "$transfer_destination/.teslausbtmp/run.*" > /dev/null
  then
    fail 'local backend left its private transfer directory behind'
  fi
  compgen -G "$transfer_destination/.teslausb-manifests/*.tsv" > /dev/null \
    || fail 'local backend did not publish an integrity manifest'

  loss_source="$TEST_TMP/loss-source"
  loss_destination="$TEST_TMP/loss-destination"
  loss_marker="$TEST_TMP/mount-identity-lost"
  mkdir -p "$loss_source" "$loss_destination"
  printf 'retain after mount loss\n' > "$loss_source/clip.txt"
  printf 'clip.txt\n' > "$TEST_TMP/loss-files.txt"
  rsync_then_lose_mount="$TEST_TMP/rsync-then-lose-mount"
  # shellcheck disable=SC2016 # This block writes a separate test script.
  printf '%s\n' \
    '#!/bin/bash' \
    'rsync "$@"' \
    'status=$?' \
    ': > "$FAKE_MOUNT_LOSS_MARKER"' \
    'exit "$status"' > "$rsync_then_lose_mount"
  chmod +x "$rsync_then_lose_mount"
  status=0
  ARCHIVE_COMMON_SH="$REPO_ROOT/run/archive-common.sh" \
  ARCHIVE_MOUNT="$loss_destination" \
  ARCHIVE_SERVER=example.invalid \
  ARCHIVE_FINDMNT_BIN="$fake_findmnt" \
  ARCHIVE_RSYNC_BIN="$rsync_then_lose_mount" \
  ARCHIVE_IS_REACHABLE="$reachable" \
  ARCHIVE_ERROR_LOG="$TEST_TMP/loss-error.log" \
  FAKE_MOUNT_LOSS_MARKER="$loss_marker" \
    bash "$REPO_ROOT/run/archive-rsync-local.sh" \
      "$loss_source" "$TEST_TMP/loss-files.txt" || status=$?
  [ "$status" -eq 76 ] || fail "mount identity loss returned $status"
  [ -f "$loss_source/clip.txt" ] || fail 'mount identity loss removed the source'
  if compgen -G "$loss_destination/.teslausb-manifests/*.tsv" > /dev/null
  then
    fail 'mount identity loss published an integrity manifest'
  fi
fi

printf 'archive common tests passed\n'
