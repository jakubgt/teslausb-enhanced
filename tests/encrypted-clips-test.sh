#!/bin/bash

# Static source assertions intentionally use literal shell-looking strings.
# shellcheck disable=SC2016

set -eu

if [ "$(id -u)" -ne 0 ]
then
  echo "encrypted-clips-test.sh must run as root" >&2
  exit 1
fi

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname "$TEST_DIR")
readonly REPO_ROOT
DETECTOR="$REPO_ROOT/run/detect_encrypted_clips.sh"
readonly DETECTOR
GUARDED_SNAPSHOT="$REPO_ROOT/run/guarded_snapshot.sh"
readonly GUARDED_SNAPSHOT
SNAPSHOT_POLICY="$REPO_ROOT/run/snapshot_contains_encrypted_clips.sh"
readonly SNAPSHOT_POLICY
TEST_TMP=$(mktemp -d /tmp/teslausb-encrypted-test.XXXXXX)
readonly TEST_TMP
cleanup() {
  if [ -n "${guard_pid:-}" ]
  then
    touch "${snapshot_release:-$TEST_TMP/snapshot-release}" 2> /dev/null || true
    kill "$guard_pid" 2> /dev/null || true
    wait "$guard_pid" 2> /dev/null || true
  fi
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/camera/TeslaCam" "$TEST_TMP/snapshot/TeslaCam"
status_file="$TEST_TMP/status/encrypted.json"

result=$(bash "$DETECTOR" --status-file "$status_file" \
  "$TEST_TMP/camera/TeslaCam" "$TEST_TMP/snapshot/TeslaCam")
[[ "$result" == *'"detected":false'* ]]
[ -f "$status_file" ]
[ "$(stat -c '%u:%g:%a' "$status_file")" = '0:0:644' ]

mkdir -p "$TEST_TMP/camera/TeslaCam/EncryptedClips/event"
printf 'opaque encrypted data\n' > "$TEST_TMP/camera/TeslaCam/EncryptedClips/event/clip.bin"
clip_before=$(stat -c '%i:%s:%Y:%a' "$TEST_TMP/camera/TeslaCam/EncryptedClips/event/clip.bin")
clip_hash_before=$(sha256sum "$TEST_TMP/camera/TeslaCam/EncryptedClips/event/clip.bin")
result=$(bash "$DETECTOR" --status-file "$status_file" \
  "$TEST_TMP/camera/TeslaCam" "$TEST_TMP/snapshot/TeslaCam")
[[ "$result" == *'"detected":true'* ]]
[[ "$result" == *'"locations":1'* ]]
[[ "$result" == *'leaves them untouched'* ]]
[ "$clip_before" = "$(stat -c '%i:%s:%Y:%a' "$TEST_TMP/camera/TeslaCam/EncryptedClips/event/clip.bin")" ]
[ "$clip_hash_before" = "$(sha256sum "$TEST_TMP/camera/TeslaCam/EncryptedClips/event/clip.bin")" ]

mkdir -p "$TEST_TMP/snapshot/TeslaCam/EncryptedClips"
result=$(bash "$DETECTOR" "$TEST_TMP/camera/TeslaCam" "$TEST_TMP/snapshot/TeslaCam")
[[ "$result" == *'"locations":2'* ]]

if bash "$DETECTOR" --unknown-option > /dev/null 2>&1
then
  echo "detector accepted an unknown option" >&2
  exit 1
fi

# The post-filter policy removes literal paths and differently-named aliases
# that resolve into EncryptedClips without opening their contents.
policy_root="$TEST_TMP/policy-root"
mkdir -p "$policy_root/SavedClips/event" \
  "$policy_root/SavedClips/EncryptedClipsish" \
  "$policy_root/EncryptedClips/event" "$policy_root/TeslaTrackMode"
touch "$policy_root/SavedClips/event/front.mp4" \
  "$policy_root/SavedClips/EncryptedClipsish/keep.mp4" \
  "$policy_root/EncryptedClips/event/clip.bin" \
  "$policy_root/TeslaTrackMode/lap.mp4"
ln -s ../EncryptedClips/event/clip.bin "$policy_root/SavedClips/opaque-alias.mp4"
archive_list="$TEST_TMP/archive-candidates.txt"
printf '%s\n' \
  'SavedClips/event/front.mp4' \
  'EncryptedClips' \
  'EncryptedClips/event/clip.bin' \
  'TeslaCam/EncryptedClips/event/clip.bin' \
  './EncryptedClips/event/clip.bin' \
  'SavedClips/opaque-alias.mp4' \
  'SavedClips/EncryptedClipsish/keep.mp4' \
  'TeslaTrackMode/lap.mp4' > "$archive_list"
bash "$DETECTOR" --prune-archive-list "$archive_list" \
  --archive-root "$policy_root"
printf '%s\n' \
  'SavedClips/event/front.mp4' \
  'SavedClips/EncryptedClipsish/keep.mp4' \
  'TeslaTrackMode/lap.mp4' > "$TEST_TMP/archive-candidates.expected"
cmp "$TEST_TMP/archive-candidates.expected" "$archive_list"

ln -s "$archive_list" "$TEST_TMP/archive-candidates.link"
if bash "$DETECTOR" --prune-archive-list "$TEST_TMP/archive-candidates.link" \
    --archive-root "$policy_root" \
    > /dev/null 2>&1
then
  echo "archive policy accepted a symbolic-link candidate list" >&2
  exit 1
fi

# Exercise the real manifest builder after policy enforcement. The encrypted
# path must not be measured or appear in the resulting manifest.
mkdir -p "$TEST_TMP/archive-source/SavedClips/event" \
  "$TEST_TMP/archive-source/EncryptedClips/event"
printf 'standard recording\n' > "$TEST_TMP/archive-source/SavedClips/event/front.mp4"
printf 'opaque encrypted recording\n' > "$TEST_TMP/archive-source/EncryptedClips/event/clip.bin"
manifest_candidates="$TEST_TMP/manifest-candidates.txt"
printf '%s\n' \
  'SavedClips/event/front.mp4' \
  'EncryptedClips/event/clip.bin' > "$manifest_candidates"
bash "$DETECTOR" --prune-archive-list "$manifest_candidates" \
  --archive-root "$TEST_TMP/archive-source"
# shellcheck source=run/archive-common.sh
source "$REPO_ROOT/run/archive-common.sh"
archive_manifest_create "$TEST_TMP/archive-source" "$manifest_candidates" \
  "$TEST_TMP/archive-manifest.tsv"
grep -F 'SavedClips/event/front.mp4' "$TEST_TMP/archive-manifest.tsv" > /dev/null
if grep -F 'EncryptedClips' "$TEST_TMP/archive-manifest.tsv" > /dev/null
then
  echo "encrypted clip entered an archive manifest" >&2
  exit 1
fi

if grep -E -i 'private.?key|tesla.?account.?token' "$DETECTOR" > /dev/null
then
  echo "detector contains key-handling behavior" >&2
  exit 1
fi
if grep -E -v '^[[:space:]]*#' "$DETECTOR" \
    | grep -E -i '(^|[;&|[:space:]])(openssl|gpg|age|tesla-control)([;&|[:space:]]|$)' > /dev/null
then
  echo "detector invokes cryptographic or Tesla-account tooling" >&2
  exit 1
fi
grep -F '! -path "${CAM_MOUNT}/TeslaCam/EncryptedClips/*"' "$REPO_ROOT/run/archiveloop" > /dev/null
[ "$(grep -F -c "! -path './TeslaCam/EncryptedClips/*'" "$REPO_ROOT/run/archiveloop")" -ge 2 ]
grep -F 'latest_snapshot=$(find /backingfiles/snapshots' "$REPO_ROOT/run/archiveloop" > /dev/null

# All three snapshot entry points (startup, steady state, and the background
# loop), plus Samba, must route through the shared guarded entrypoint.
archive_loop="$REPO_ROOT/run/archiveloop"
[ "$(grep -F -c '/root/bin/make_snapshot.sh' "$archive_loop")" -eq 0 ]
[ "$(grep -F -c '/root/bin/guarded_snapshot.sh' "$archive_loop")" -eq 1 ]
[ "$(grep -F -c 'prepare_camera_snapshot' "$archive_loop")" -eq 4 ]
[ "$(grep -F -c 'archive_clips "$camera_archive_allowed"' "$archive_loop")" -eq 2 ]
grep -F 'root preexec = /root/bin/guarded_snapshot.sh' \
  "$REPO_ROOT/setup/pi/configure-samba.sh" > /dev/null
if grep -F 'root preexec = /root/bin/make_snapshot.sh' \
    "$REPO_ROOT/setup/pi/configure-samba.sh" > /dev/null
then
  echo "Samba still invokes the raw snapshot helper" >&2
  exit 1
fi
policy_line=$(grep -n -F -- '--prune-archive-list "$sentrylist"' "$archive_loop" | cut -d: -f1)
manifest_line=$(grep -n -F 'archive_manifest_create "$overlaymerged"' "$archive_loop" | cut -d: -f1)
[ -n "$policy_line" ] && [ -n "$manifest_line" ] && [ "$policy_line" -lt "$manifest_line" ]
grep -F -- '--archive-root "$overlaymerged"' "$archive_loop" > /dev/null
camera_skip_line=$(grep -n -F 'elif [ "$camera_archive_allowed" != true ]' "$archive_loop" | cut -d: -f1)
music_sync_line=$(grep -n -F 'if timeout 5 [ -d "${MUSIC_ARCHIVE_MOUNT:-}"' "$archive_loop" | cut -d: -f1)
[ -n "$camera_skip_line" ] && [ -n "$music_sync_line" ] && [ "$camera_skip_line" -lt "$music_sync_line" ]
background_prepare_line=$(grep -n -F 'prepare_camera_snapshot || snapshot_status=$?' "$archive_loop" | head -n 1 | cut -d: -f1)
background_reconnect_line=$(grep -n -F 'connect_usb_drives_to_host || log "Failed to reconnect USB drives after background snapshot check"' "$archive_loop" | cut -d: -f1)
[ -n "$background_prepare_line" ] && [ -n "$background_reconnect_line" ] && \
  [ "$background_prepare_line" -lt "$background_reconnect_line" ]

# Exercise the real guarded entrypoint with fake mount/gadget helpers. Every
# helper asserts that the outer gadget lock's held-lock convention propagated.
guard_fixture="$TEST_TMP/guard"
mkdir -p "$guard_fixture/bin" "$guard_fixture/cam/TeslaCam" \
  "$guard_fixture/mutable/TeslaCam" "$guard_fixture/run" \
  "$guard_fixture/status"
printf 'dwc2-test\n' > "$guard_fixture/UDC"
touch "$guard_fixture/envsetup"

printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  'printf "disable\n" >> "$FAKE_CALL_LOG"' > "$guard_fixture/bin/disable"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  'printf "enable\n" >> "$FAKE_CALL_LOG"' > "$guard_fixture/bin/enable"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  'printf "mount\n" >> "$FAKE_CALL_LOG"' \
  'touch "$FAKE_MOUNT_MARKER"' > "$guard_fixture/bin/mount"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  'printf "umount\n" >> "$FAKE_CALL_LOG"' \
  'if [ "${FAKE_UMOUNT_FAIL:-}" = 1 ]; then exit 1; fi' \
  'rm -f -- "$FAKE_MOUNT_MARKER"' > "$guard_fixture/bin/umount"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  '[ -e "$FAKE_MOUNT_MARKER" ]' > "$guard_fixture/bin/findmnt"
printf '%s\n' '#!/bin/bash' 'set -eu' 'exit 0' > "$guard_fixture/bin/detector"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  '[ "${TESLAUSB_GADGET_LOCK_HELD:-}" = 1 ]' \
  'printf "snapshot-start:%s\n" "$*" >> "$FAKE_CALL_LOG"' \
  'if [ -n "${FAKE_SNAPSHOT_STARTED:-}" ]; then touch "$FAKE_SNAPSHOT_STARTED"; fi' \
  'while [ -n "${FAKE_SNAPSHOT_WAIT_FOR:-}" ] && [ ! -e "$FAKE_SNAPSHOT_WAIT_FOR" ]; do sleep 0.02; done' \
  'printf "snapshot-end\n" >> "$FAKE_CALL_LOG"' > "$guard_fixture/bin/snapshot"
chmod +x "$guard_fixture/bin/"*

run_guarded_snapshot() {
  TESLAUSB_GUARDED_SNAPSHOT_TEST_OVERRIDES=1 \
  TESLAUSB_GADGET_RUN_DIR="$guard_fixture/run" \
  TESLAUSB_CAM_MOUNT="$guard_fixture/cam" \
  TESLAUSB_MUTABLE_TESLACAM="$guard_fixture/mutable/TeslaCam" \
  TESLAUSB_SNAPSHOTS_ROOT="$guard_fixture/snapshots" \
  TESLAUSB_ENCRYPTED_STATUS_FILE="$guard_fixture/status/status.json" \
  TESLAUSB_ENVSETUP="$guard_fixture/envsetup" \
  TESLAUSB_DISABLE_GADGET="$guard_fixture/bin/disable" \
  TESLAUSB_ENABLE_GADGET="$guard_fixture/bin/enable" \
  TESLAUSB_RAW_SNAPSHOT_HELPER="$guard_fixture/bin/snapshot" \
  TESLAUSB_ENCRYPTED_CLIPS_DETECTOR="$guard_fixture/bin/detector" \
  TESLAUSB_GADGET_ACTIVE_FILE="$guard_fixture/UDC" \
  TESLAUSB_MOUNT_COMMAND="$guard_fixture/bin/mount" \
  TESLAUSB_UMOUNT_COMMAND="$guard_fixture/bin/umount" \
  TESLAUSB_FINDMNT_COMMAND="$guard_fixture/bin/findmnt" \
  TESLAUSB_GADGET_LOCK_TIMEOUT="${GUARD_LOCK_TIMEOUT:-2}" \
  FAKE_CALL_LOG="$guard_fixture/calls" \
  FAKE_MOUNT_MARKER="$guard_fixture/mounted" \
  FAKE_UMOUNT_FAIL="${FAKE_UMOUNT_FAIL:-}" \
  FAKE_SNAPSHOT_STARTED="${FAKE_SNAPSHOT_STARTED:-}" \
  FAKE_SNAPSHOT_WAIT_FOR="${FAKE_SNAPSHOT_WAIT_FOR:-}" \
  LOG_FILE="$guard_fixture/guard.log" \
    bash "$GUARDED_SNAPSHOT" "$@"
}

mkdir -p "$guard_fixture/cam/TeslaCam/EncryptedClips/event"
snapshot_status=0
run_guarded_snapshot --leave-disconnected nofsck || snapshot_status=$?
[ "$snapshot_status" -eq 75 ]
if grep -F 'snapshot-start' "$guard_fixture/calls" > /dev/null
then
  echo "guarded snapshot copied a live EncryptedClips directory" >&2
  exit 1
fi

rm -rf -- "$guard_fixture/cam/TeslaCam/EncryptedClips"
true > "$guard_fixture/calls"
run_guarded_snapshot nofsck
[ "$(<"$guard_fixture/calls")" = $'disable\nmount\numount\nsnapshot-start:nofsck\nsnapshot-end\nenable' ]

# If neither a normal nor lazy unmount can be verified, fail closed and do not
# reconnect the gadget to the still-mounted backing image.
true > "$guard_fixture/calls"
snapshot_status=0
FAKE_UMOUNT_FAIL=1 run_guarded_snapshot nofsck || snapshot_status=$?
[ "$snapshot_status" -ne 0 ]
if grep -Eq '^(snapshot-start:|enable$)' "$guard_fixture/calls"
then
  echo "guarded snapshot reconnected or copied after an unmount failure" >&2
  exit 1
fi
rm -f -- "$guard_fixture/mounted"

# A competing guarded/manual gadget operation cannot enter while the first
# process is between the live check and the raw snapshot completion.
true > "$guard_fixture/calls"
snapshot_started="$guard_fixture/snapshot-started"
snapshot_release="$guard_fixture/snapshot-release"
FAKE_SNAPSHOT_STARTED="$snapshot_started" \
FAKE_SNAPSHOT_WAIT_FOR="$snapshot_release" \
  run_guarded_snapshot nofsck > "$guard_fixture/first.out" 2>&1 &
guard_pid=$!
for _ in {1..100}
do
  [ -e "$snapshot_started" ] && break
  sleep 0.02
done
[ -e "$snapshot_started" ] || {
  echo "guarded snapshot concurrency fixture did not start" >&2
  exit 1
}
snapshot_status=0
GUARD_LOCK_TIMEOUT=0 run_guarded_snapshot --leave-disconnected nofsck \
  > "$guard_fixture/second.out" 2>&1 || snapshot_status=$?
[ "$snapshot_status" -eq 75 ]
[ "$(grep -c '^disable$' "$guard_fixture/calls")" -eq 1 ]
[ "$(grep -c '^snapshot-start:' "$guard_fixture/calls")" -eq 1 ]
touch "$snapshot_release"
wait "$guard_pid"
guard_pid=
[ "$(tail -n 1 "$guard_fixture/calls")" = enable ]

# Legacy snapshots are classified from their read-only directory views. An
# absent/unreadable view is unknown and therefore protected from automation.
snapshot_root="$TEST_TMP/snapshots"
snapshot_mount_root="$TEST_TMP/snapshot-mounts"
mutable_root="$TEST_TMP/release-mutable/TeslaCam"
mkdir -p "$snapshot_root/snap-000001/mnt/TeslaCam/EncryptedClips/event" \
  "$snapshot_root/snap-000002/mnt/TeslaCam" \
  "$snapshot_root/snap-000004" "$snapshot_mount_root" \
  "$mutable_root/EncryptedClips" "$mutable_root/SavedClips"
touch "$snapshot_root/snap-000001/snap.bin" \
  "$snapshot_root/snap-000002/snap.bin" \
  "$snapshot_root/snap-000004/snap.bin"
policy_findmnt="$TEST_TMP/policy-findmnt"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$policy_findmnt"
chmod +x "$policy_findmnt"

policy_status=0
SNAPSHOTS_ROOT="$snapshot_root" SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
  bash "$SNAPSHOT_POLICY" snap-000001 || policy_status=$?
[ "$policy_status" -eq 0 ]
policy_status=0
SNAPSHOTS_ROOT="$snapshot_root" SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
  bash "$SNAPSHOT_POLICY" snap-000002 || policy_status=$?
[ "$policy_status" -eq 1 ]
policy_status=0
SNAPSHOTS_ROOT="$snapshot_root" SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
  bash "$SNAPSHOT_POLICY" snap-000004 || policy_status=$?
[ "$policy_status" -eq 2 ]

ln -s "$snapshot_root/snap-000001/mnt/TeslaCam/EncryptedClips/event" \
  "$mutable_root/EncryptedClips/legacy-link"
ln -s "$snapshot_root/snap-000001/mnt/TeslaCam/EncryptedClips/event" \
  "$mutable_root/SavedClips/opaque-alias"
TESLAUSB_TEST_RELEASE_LOG="$TEST_TMP/release.log"
export TESLAUSB_TEST_RELEASE_LOG
function log () { printf '%s\n' "$*" >> "$TESLAUSB_TEST_RELEASE_LOG"; }
export -f log
bash -eu -c 'log "fixture-ready"'
grep -Fx 'fixture-ready' "$TESLAUSB_TEST_RELEASE_LOG" > /dev/null
policy_bin="$TEST_TMP/policy-bin"
mkdir -p "$policy_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$policy_bin/umount"
chmod +x "$policy_bin/umount"
release_script="$REPO_ROOT/run/release_snapshot.sh"
release_status=0
PATH="$policy_bin:$PATH" BACKINGFILES_ROOT="$TEST_TMP/backingfiles-unused" \
SNAPSHOTS_ROOT="$snapshot_root" SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
MUTABLE_TESLACAM="$mutable_root" SNAPSHOT_POLICY_HELPER="$SNAPSHOT_POLICY" \
  bash -eu "$release_script" snap-000001 || release_status=$?
[ "$release_status" -eq 75 ]
[ -d "$snapshot_root/snap-000001" ]
[ -L "$mutable_root/EncryptedClips/legacy-link" ]
[ -L "$mutable_root/SavedClips/opaque-alias" ]

# Low-space rotation skips protected and unknown snapshots, deletes the oldest
# confirmed-clear snapshot, then stops safely when none remain.
mkdir -p "$snapshot_root/snap-000003/mnt/TeslaCam"
touch "$snapshot_root/snap-000003/snap.bin"
printf '%s\n' '#!/bin/bash' 'set -eu' \
  'if [ "${1:-}" = --file-system ]; then printf "%s\n" "echo 0"; else exec /usr/bin/stat "$@"; fi' \
  > "$policy_bin/stat"
chmod +x "$policy_bin/stat"
manage_script="$REPO_ROOT/run/manage_free_space.sh"
manage_status=0
FLOCKED="$manage_script" PATH="$policy_bin:$PATH" \
BACKINGFILES_ROOT="$TEST_TMP/backingfiles-unused" SNAPSHOTS_ROOT="$snapshot_root" \
SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" MUTABLE_TESLACAM="$mutable_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
SNAPSHOT_POLICY_HELPER="$SNAPSHOT_POLICY" RELEASE_SNAPSHOT="$release_script" \
  timeout 15s bash -eu "$manage_script" 1 || manage_status=$?
[ "$manage_status" -eq 1 ]
[ -d "$snapshot_root/snap-000001" ]
[ ! -e "$snapshot_root/snap-000002" ]
[ -d "$snapshot_root/snap-000004" ]

# A failed releaser must stop rotation instead of selecting the same snapshot
# forever while the low-space condition remains true.
mkdir -p "$snapshot_root/snap-000005/mnt/TeslaCam"
touch "$snapshot_root/snap-000005/snap.bin"
printf '%s\n' '#!/bin/sh' 'exit 42' > "$policy_bin/release-fail"
chmod +x "$policy_bin/release-fail"
manage_status=0
FLOCKED="$manage_script" PATH="$policy_bin:$PATH" \
BACKINGFILES_ROOT="$TEST_TMP/backingfiles-unused" SNAPSHOTS_ROOT="$snapshot_root" \
SNAPSHOT_MOUNT_ROOT="$snapshot_mount_root" MUTABLE_TESLACAM="$mutable_root" \
SNAPSHOT_FINDMNT_COMMAND="$policy_findmnt" \
SNAPSHOT_POLICY_HELPER="$SNAPSHOT_POLICY" RELEASE_SNAPSHOT="$policy_bin/release-fail" \
  timeout 5s bash -eu "$manage_script" 1 || manage_status=$?
[ "$manage_status" -eq 1 ]
[ -d "$snapshot_root/snap-000005" ]
grep -F 'snapshot release failed for' "$TESLAUSB_TEST_RELEASE_LOG" > /dev/null

# The listing and FUSE viewer layers both enforce literal and resolved-path
# exclusions; nginx independently blocks direct EncryptedClips URLs.
grep -F 'resolved_path=$(realpath -e -- "/mutable/TeslaCam/$path"' \
  "$REPO_ROOT/teslausb-www/html/cgi-bin/videolist.sh" > /dev/null
grep -F 'is_encrypted_request_path(path)' \
  "$REPO_ROOT/teslausb-www/cttseraser.cpp" > /dev/null
grep -F 'location ~* ^/TeslaCam/(?:.*/)?EncryptedClips(?:/|$)' \
  "$REPO_ROOT/teslausb-www/teslausb.nginx" > /dev/null

mkdir -p "$TEST_TMP/fake-bin"
printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/fake-bin/find"
chmod +x "$TEST_TMP/fake-bin/find"
status_response=$(PATH="$TEST_TMP/fake-bin:$PATH" \
  ENCRYPTED_CLIPS_STATUS_FILE="$status_file" REQUEST_METHOD=GET \
  bash "$REPO_ROOT/teslausb-www/html/cgi-bin/status.sh")
[[ "$status_response" == *'"encrypted_clips": {"schema_version":1,"detected":true'* ]]
[[ "$status_response" == *'"message":"Encrypted Dashcam clips detected. TeslaUSB leaves them untouched and cannot archive or play them.","available":true}'* ]]

chmod 0664 "$status_file"
status_response=$(PATH="$TEST_TMP/fake-bin:$PATH" \
  ENCRYPTED_CLIPS_STATUS_FILE="$status_file" REQUEST_METHOD=GET \
  bash "$REPO_ROOT/teslausb-www/html/cgi-bin/status.sh")
[[ "$status_response" == *'"encrypted_clips": {"schema_version":1,"detected":false,"locations":0,"checked_at":"","message":"Encrypted-clip detection has not run yet.","available":false}'* ]]

echo "encrypted clip detection tests passed"
