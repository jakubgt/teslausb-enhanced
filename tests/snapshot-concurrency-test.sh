#!/bin/bash -eu

# Real Linux flock plus fake block-device operations. No root or loop devices
# required: ordering, inherited descriptor validation and deferred work are the
# behavior under test, rather than the host's filesystem/reflink support.
TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$TEST_DIR")
TEST_TMP=$(mktemp -d /tmp/teslausb-snapshot-concurrency.XXXXXX)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export TEST_TMP
export CALLS="$TEST_TMP/calls"
export LOG_FILE="$TEST_TMP/log"
export BACKINGFILES_ROOT="$TEST_TMP/backing-2026"
export SNAPSHOTS_ROOT="$BACKINGFILES_ROOT/snapshots"
export SNAPSHOT_MOUNT_ROOT="$TEST_TMP/mounts"
export MUTABLE_TESLACAM="$TEST_TMP/mutable/TeslaCam"
mkdir -p "$SNAPSHOTS_ROOT" "$SNAPSHOT_MOUNT_ROOT" "$MUTABLE_TESLACAM" \
  "$TEST_TMP/bin" "$TEST_TMP/cam/TeslaCam"
touch "$BACKINGFILES_ROOT/cam_disk.bin" "$TEST_TMP/envsetup" "$CALLS"

cat > "$TEST_TMP/bin/disable" <<'HELPER'
#!/bin/bash -eu
printf 'disable\n' >> "$CALLS"
: > "$TESLAUSB_GADGET_ACTIVE_FILE"
HELPER
cat > "$TEST_TMP/bin/enable" <<'HELPER'
#!/bin/bash -eu
printf 'enable\n' >> "$CALLS"
printf 'dwc2-test\n' > "$TESLAUSB_GADGET_ACTIVE_FILE"
HELPER
cat > "$TEST_TMP/bin/mount" <<'HELPER'
#!/bin/bash -eu
printf 'mount-live\n' >> "$CALLS"
touch "$TEST_TMP/live-mounted"
HELPER
cat > "$TEST_TMP/bin/unmount" <<'HELPER'
#!/bin/bash -eu
printf 'unmount-live\n' >> "$CALLS"
rm -f -- "$TEST_TMP/live-mounted"
HELPER
cat > "$TEST_TMP/bin/findmnt" <<'HELPER'
#!/bin/bash -eu
[ -f "$TEST_TMP/live-mounted" ]
HELPER
cat > "$TEST_TMP/bin/clear-policy" <<'HELPER'
#!/bin/bash -eu
exit 1
HELPER
chmod +x "$TEST_TMP/bin/"*

export TESLAUSB_GUARDED_SNAPSHOT_TEST_OVERRIDES=1
export TESLAUSB_GADGET_RUN_DIR="$TEST_TMP/run"
export TESLAUSB_CAM_MOUNT="$TEST_TMP/cam"
export TESLAUSB_MUTABLE_TESLACAM="$MUTABLE_TESLACAM"
export TESLAUSB_SNAPSHOTS_ROOT="$SNAPSHOTS_ROOT"
export TESLAUSB_ENCRYPTED_STATUS_FILE="$TEST_TMP/status.json"
export TESLAUSB_ENVSETUP="$TEST_TMP/envsetup"
export TESLAUSB_DISABLE_GADGET="$TEST_TMP/bin/disable"
export TESLAUSB_ENABLE_GADGET="$TEST_TMP/bin/enable"
export TESLAUSB_RAW_SNAPSHOT_HELPER="$REPO_ROOT/run/make_snapshot.sh"
export TESLAUSB_ENCRYPTED_CLIPS_DETECTOR=/bin/true
export TESLAUSB_ENCRYPTED_PATH_STATUS_HELPER="$REPO_ROOT/run/encrypted_clips_path_status.sh"
export TESLAUSB_GADGET_ACTIVE_FILE="$TEST_TMP/UDC"
export TESLAUSB_MOUNT_COMMAND="$TEST_TMP/bin/mount"
export TESLAUSB_UMOUNT_COMMAND="$TEST_TMP/bin/unmount"
export TESLAUSB_FINDMNT_COMMAND="$TEST_TMP/bin/findmnt"
export SNAPSHOT_POLICY_HELPER="$TEST_TMP/bin/clear-policy"
export TESLAUSB_GADGET_LOCK_TIMEOUT=0

function log { printf '%s\n' "$*" >> "$LOG_FILE"; }
function cp {
  printf 'reflink\n' >> "$CALLS"
  touch "${@: -1}"
}
function mount { return 0; }
function losetup_find_show {
  printf 'process-snapshot\n' >> "$CALLS"
  printf '/dev/loop-test\n'
}
function losetup { return 0; }
function systemctl { return 0; }
function getconf { printf '64\n'; }
function umount { printf 'release-snapshot\n' >> "$CALLS"; }
export -f log cp mount losetup_find_show losetup systemctl getconf umount

guarded="$REPO_ROOT/run/guarded_snapshot.sh"
raw="$REPO_ROOT/run/make_snapshot.sh"
manager="$REPO_ROOT/run/manage_free_space.sh"
releaser="$REPO_ROOT/run/release_snapshot.sh"

function expect_status {
  local wanted="$1" actual=0
  shift
  "$@" || actual=$?
  [ "$actual" -eq "$wanted" ] || {
    echo "FAIL: expected $wanted, got $actual from $*" >&2
    exit 1
  }
}

# A real cleanup lock must defer both guarded and direct callers promptly.
# FLOCKED was the old spoofable bypass and must no longer bypass this lock.
exec {held}< "$SNAPSHOTS_ROOT"
flock -n "$held"
printf 'dwc2-test\n' > "$TEST_TMP/UDC"
expect_status 99 timeout 3 bash "$guarded" --connect-after-copy nofsck
FLOCKED="$raw" expect_status 99 timeout 3 bash "$raw" nofsck
FLOCKED="$manager" expect_status 99 timeout 3 bash "$manager" 1
expect_status 99 timeout 3 bash "$releaser" snap-000000
exec {separate}< "$SNAPSHOTS_ROOT"
TESLAUSB_SNAPSHOT_LOCK_FD="$separate" expect_status 99 timeout 3 bash "$raw" nofsck
exec {separate}<&-
[ ! -s "$CALLS" ]
[ -s "$TEST_TMP/UDC" ]
exec {held}<&-

# An inherited handle must identify this directory and obtain/retain the same
# flock. Closed and wrong-inode descriptors are rejected before USB changes.
TESLAUSB_SNAPSHOT_LOCK_FD=999 expect_status 64 bash "$guarded" nofsck
TESLAUSB_SNAPSHOT_LOCK_FD=999 expect_status 64 bash "$raw" nofsck
TESLAUSB_SNAPSHOT_LOCK_FD=9 expect_status 64 bash "$guarded" nofsck
exec {wrong}< "$TEST_TMP/envsetup"
TESLAUSB_SNAPSHOT_LOCK_FD="$wrong" expect_status 64 bash "$raw" nofsck
exec {wrong}<&-
[ ! -s "$CALLS" ]

# Direct callers acquire their own lock; a guard passes its actual descriptor
# through to the raw helper without deadlock. Reconnect precedes processing.
mkdir -p "$SNAPSHOT_MOUNT_ROOT/snap-000000/TeslaCam/RecentClips"
printf 'test clip\n' > "$SNAPSHOT_MOUNT_ROOT/snap-000000/TeslaCam/RecentClips/2026-09-04_12-00-00-front.mp4"
timeout 5 bash "$guarded" --connect-after-copy nofsck
[ "$(<"$CALLS")" = $'disable\nmount-live\nunmount-live\nreflink\nenable\nprocess-snapshot' ]
[ -s "$SNAPSHOTS_ROOT/snap-000000/snap.bin.toc" ]
[ -L "$MUTABLE_TESLACAM/RecentClips/2026-09-04/2026-09-04_12-00-00-front.mp4" ]

# Identical snapshot disposal (formerly several minutes with USB offline)
# must also occur after reconnect, with exactly one gadget enable.
mkdir -p "$SNAPSHOT_MOUNT_ROOT/snap-000001/TeslaCam/RecentClips"
printf 'test clip\n' > "$SNAPSHOT_MOUNT_ROOT/snap-000001/TeslaCam/RecentClips/2026-09-04_12-00-00-front.mp4"
: > "$CALLS"
timeout 5 bash "$guarded" --connect-after-copy nofsck
[ "$(<"$CALLS")" = $'disable\nmount-live\nunmount-live\nreflink\nenable\nprocess-snapshot\nrelease-snapshot' ]
[ ! -e "$SNAPSHOTS_ROOT/snap-000001" ]

# An archive transaction explicitly keeps USB disconnected through processing.
: > "$CALLS"
timeout 5 bash "$guarded" --leave-disconnected nofsck
if grep -q '^enable$' "$CALLS"; then echo 'archive reconnected too early' >&2; exit 1; fi
[ ! -s "$TEST_TMP/UDC" ]

# The standalone raw helper takes/releases its own lock without environment
# claims; subsequent direct release can take that lock too.
: > "$CALLS"
timeout 5 bash "$raw" nofsck
[ "$(head -n 1 "$CALLS")" = reflink ]
exec {verify}< "$SNAPSHOTS_ROOT"
flock -n "$verify"
exec {verify}<&-

# Release walks link metadata once and resolves only links to the selected
# snapshot. Literal encrypted paths and aliases resolving there remain intact.
mkdir -p "$TEST_TMP/protected/EncryptedClips" \
  "$SNAPSHOT_MOUNT_ROOT/snap-000000/TeslaCam/SavedClips" \
  "$MUTABLE_TESLACAM/SavedClips"
touch "$TEST_TMP/protected/EncryptedClips/clip.bin"
ln -s "$TEST_TMP/protected/EncryptedClips/clip.bin" \
  "$SNAPSHOT_MOUNT_ROOT/snap-000000/TeslaCam/SavedClips/opaque"
ln -s "$SNAPSHOTS_ROOT/snap-000000/mnt/TeslaCam/SavedClips/opaque" \
  "$MUTABLE_TESLACAM/SavedClips/protected-alias"
ln -s "$SNAPSHOTS_ROOT/snap-000000/mnt/TeslaCam/EncryptedClips/clip.bin" \
  "$MUTABLE_TESLACAM/SavedClips/protected-literal"
ln -s "$SNAPSHOTS_ROOT/snap-999999/mnt/TeslaCam/RecentClips/other.mp4" \
  "$MUTABLE_TESLACAM/SavedClips/unrelated"
function realpath {
  printf '%s\n' "${@: -1}" >> "$TEST_TMP/resolved-links"
  command realpath "$@"
}
export -f realpath
timeout 5 bash "$releaser" snap-000000
[ ! -e "$SNAPSHOTS_ROOT/snap-000000" ]
[ ! -L "$MUTABLE_TESLACAM/RecentClips/2026-09-04/2026-09-04_12-00-00-front.mp4" ]
[ -L "$MUTABLE_TESLACAM/SavedClips/protected-alias" ]
[ -L "$MUTABLE_TESLACAM/SavedClips/protected-literal" ]
[ -L "$MUTABLE_TESLACAM/SavedClips/unrelated" ]
if grep -Eq '/(unrelated|protected-literal)$' "$TEST_TMP/resolved-links"
then
  echo 'release unnecessarily resolved unrelated or encrypted links' >&2
  exit 1
fi

echo 'snapshot concurrency and USB ordering tests passed'
