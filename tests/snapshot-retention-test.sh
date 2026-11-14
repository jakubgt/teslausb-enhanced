#!/bin/bash -eu

# Exercise the real retention/release helpers against disposable files and
# mocked block-device metadata. Real flock still protects the fixture directory.
TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "$TEST_DIR")
TEST_TMP=$(mktemp -d /tmp/teslausb-snapshot-retention.XXXXXX)
readonly TEST_DIR REPO_ROOT TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_status() {
  local wanted="$1" actual=0
  shift
  "$@" || actual=$?
  [ "$actual" -eq "$wanted" ] || fail "expected $wanted, got $actual"
}

mkdir "$TEST_TMP/bin"
export REAL_STAT REAL_FIND
REAL_STAT=$(command -v stat)
REAL_FIND=$(command -v find)
cat > "$TEST_TMP/bin/stat" <<'EOF'
#!/bin/bash -eu
if [ "${1:-}" = --file-system ]
then
  remaining=$(find "$SNAPSHOTS_ROOT" -mindepth 2 -maxdepth 2 -type f -name snap.bin | wc -l)
  if [ "$remaining" -le "$FREE_WHEN_REMAINING" ]
  then
    printf 'echo 100\n'
  else
    printf 'echo 0\n'
  fi
elif [ "${BAD_MARKER_OWNER:-0}" = 1 ] && [[ "${@: -1}" == */snap.bin.toc ]]
then
  printf '999999:1:600\n'
elif [ "${MARKER_STAT_ERROR:-0}" = 1 ] && [[ "${@: -1}" == */snap.bin.toc ]]
then
  exit 1
else
  exec "$REAL_STAT" "$@"
fi
EOF
cat > "$TEST_TMP/bin/find" <<'EOF'
#!/bin/bash -eu
if [ "${MARKER_FIND_ERROR:-0}" = 1 ] && [[ "$*" == *'-name snap.bin.toc '* ]]
then
  exit 1
fi
exec "$REAL_FIND" "$@"
EOF
cat > "$TEST_TMP/bin/policy" <<'EOF'
#!/bin/bash -eu
[ ! -f "$SNAPSHOTS_ROOT/$1/encrypted" ] || exit 0
[ ! -f "$SNAPSHOTS_ROOT/$1/unknown" ] || exit 2
exit 1
EOF
cat > "$TEST_TMP/bin/umount" <<'EOF'
#!/bin/bash -eu
printf 'umount\n' >> "$CALLS"
exit "${UNMOUNT_STATUS:-0}"
EOF
cat > "$TEST_TMP/bin/findmnt" <<'EOF'
#!/bin/bash -eu
[ "$*" = '--kernel --raw --noheadings --output TARGET' ] || exit 90
printf 'findmnt\n' >> "$CALLS"
[ "${FINDMNT_STATUS:-0}" = 0 ] || exit "$FINDMNT_STATUS"
case "${MOUNT_TABLE_MODE:-clear}" in
  clear) printf '/\n/backingfiles\n' ;;
  mounted) printf '/\n%s\n' "$SNAPSHOT_MOUNT_ROOT/snap-000001" ;;
  nested) printf '/\n%s\n' "$SNAPSHOTS_ROOT/snap-000001/other-mount" ;;
  escaped) printf '/\n%s\n' "${SNAPSHOT_MOUNT_ROOT// /\\x20}/snap-000001" ;;
  empty) : ;;
  no-root) printf '/backingfiles\n' ;;
  malformed) printf '/\nnot-an-absolute-mountpoint\n' ;;
  *) exit 91 ;;
esac
EOF
cat > "$TEST_TMP/bin/losetup" <<'EOF'
#!/bin/bash -eu
[ "$#" -eq 6 ] && [ "$1" = --list ] && [ "$2" = --associated ] &&
  [ "$4" = --noheadings ] && [ "$5" = --output ] && [ "$6" = NAME ] || exit 90
printf 'losetup\n' >> "$CALLS"
[ "${LOSETUP_STATUS:-0}" = 0 ] || exit "$LOSETUP_STATUS"
[ "${LOOP_ASSOCIATED:-0}" = 0 ] || printf '/dev/loop-fixture\n'
EOF
chmod +x "$TEST_TMP/bin/"*
export PATH="$TEST_TMP/bin:$PATH"
export SNAPSHOT_POLICY_HELPER="$TEST_TMP/bin/policy"
export SNAPSHOT_FINDMNT_COMMAND="$TEST_TMP/bin/findmnt"
export SNAPSHOT_LOSETUP_COMMAND="$TEST_TMP/bin/losetup"
manager="$REPO_ROOT/run/manage_free_space.sh"
export RELEASE_SNAPSHOT="$REPO_ROOT/run/release_snapshot.sh"
function log { printf '%s\n' "$*" >> "$LOG_FILE"; }
export -f log

new_case() {
  local name="$1"
  export BACKINGFILES_ROOT="$TEST_TMP/$name"
  export SNAPSHOTS_ROOT="$BACKINGFILES_ROOT/snapshots"
  export SNAPSHOT_MOUNT_ROOT="$BACKINGFILES_ROOT/mounts"
  export MUTABLE_TESLACAM="$BACKINGFILES_ROOT/mutable/TeslaCam"
  export LOG_FILE="$BACKINGFILES_ROOT/log"
  export CALLS="$BACKINGFILES_ROOT/calls"
  export FREE_WHEN_REMAINING=-1 BAD_MARKER_OWNER=0 MARKER_STAT_ERROR=0 MARKER_FIND_ERROR=0
  export UNMOUNT_STATUS=0 FINDMNT_STATUS=0 LOSETUP_STATUS=0 LOOP_ASSOCIATED=0
  export MOUNT_TABLE_MODE=clear
  mkdir -p "$SNAPSHOTS_ROOT" "$SNAPSHOT_MOUNT_ROOT" "$MUTABLE_TESLACAM"
  touch "$BACKINGFILES_ROOT/cam_disk.bin" "$LOG_FILE" "$CALLS"
}

snapshot() {
  local name="$1" state="${2:-incomplete}"
  mkdir "$SNAPSHOTS_ROOT/$name"
  touch "$SNAPSHOTS_ROOT/$name/snap.bin"
  if [ "$state" = complete ]
  then
    printf '16 TeslaCam/RecentClips/2026-11-14_12-00-00-front.mp4\n' > "$SNAPSHOTS_ROOT/$name/snap.bin.toc"
    chmod 0600 "$SNAPSHOTS_ROOT/$name/snap.bin.toc"
  else
    touch "$SNAPSHOTS_ROOT/$name/snap.bin.toc_"
  fi
}

new_case sole-complete
snapshot snap-000001 complete
expect_status 1 bash "$manager" 1
[ -f "$SNAPSHOTS_ROOT/snap-000001/snap.bin" ] || fail 'sole completed snapshot removed'
[ ! -s "$CALLS" ] || fail 'sole completed snapshot reached release'

new_case sole-incomplete
snapshot snap-000001
FREE_WHEN_REMAINING=0
expect_status 0 bash "$manager" 1
[ ! -e "$SNAPSHOTS_ROOT/snap-000001" ] || fail 'sole clear incomplete snapshot was not cleaned'

new_case complete-plus-incomplete
snapshot snap-000001 complete
snapshot snap-000002
FREE_WHEN_REMAINING=1
expect_status 0 bash "$manager" 1
[ -e "$SNAPSHOTS_ROOT/snap-000001/snap.bin.toc" ] || fail 'last completed snapshot removed'
[ ! -e "$SNAPSHOTS_ROOT/snap-000002" ] || fail 'incomplete snapshot blocked completed retention'

new_case complete-plus-empty-marker
snapshot snap-000001 complete
snapshot snap-000002
touch "$SNAPSHOTS_ROOT/snap-000002/snap.bin.toc"
chmod 0600 "$SNAPSHOTS_ROOT/snap-000002/snap.bin.toc"
expect_status 1 bash "$manager" 1
[ -s "$SNAPSHOTS_ROOT/snap-000001/snap.bin.toc" ] || fail 'empty final marker superseded the last nonempty completed snapshot'
[ -f "$SNAPSHOTS_ROOT/snap-000002/snap.bin" ] || fail 'empty final marker was treated as a disposable incomplete copy'
[ ! -s "$CALLS" ] || fail 'empty final marker caused a protected snapshot release'

new_case preference-and-newest
snapshot snap-000001 complete
snapshot snap-000002 complete
snapshot snap-000003
FREE_WHEN_REMAINING=1
expect_status 0 bash "$manager" 1
[ -e "$SNAPSHOTS_ROOT/snap-000002/snap.bin.toc" ] || fail 'newest completed snapshot removed'
released=$(grep '^released snapshot ' "$LOG_FILE" | cut -d ' ' -f 3)
[ "$released" = $'snap-000003\nsnap-000001' ] || fail 'incomplete copies were not preferred over old completed snapshots'

new_case two-incomplete
snapshot snap-000001
snapshot snap-000002
FREE_WHEN_REMAINING=0
expect_status 0 bash "$manager" 1
if [ -e "$SNAPSHOTS_ROOT/snap-000001" ] || [ -e "$SNAPSHOTS_ROOT/snap-000002" ]
then
  fail 'clear incomplete images were retained by an image-count guard'
fi

for protected in encrypted unknown
do
  new_case "$protected"
  snapshot snap-000001
  touch "$SNAPSHOTS_ROOT/snap-000001/$protected"
  expect_status 1 bash "$manager" 1
  [ -f "$SNAPSHOTS_ROOT/snap-000001/snap.bin" ] || fail 'protected/unknown snapshot removed'
  [ ! -s "$CALLS" ] || fail 'protected/unknown snapshot reached release'
done

for marker in empty symlink directory writable hardlink wrong-owner stat-error list-error
do
  new_case "marker-$marker"
  snapshot snap-000001
  toc="$SNAPSHOTS_ROOT/snap-000001/snap.bin.toc"
  case "$marker" in
    empty) touch "$toc"; chmod 0600 "$toc" ;;
    symlink) touch "$BACKINGFILES_ROOT/elsewhere"; ln -s "$BACKINGFILES_ROOT/elsewhere" "$toc" ;;
    directory) mkdir "$toc" ;;
    writable) printf '16 TeslaCam/clip.mp4\n' > "$toc"; chmod 0666 "$toc" ;;
    hardlink) printf '16 TeslaCam/clip.mp4\n' > "$toc"; chmod 0600 "$toc"; ln "$toc" "$BACKINGFILES_ROOT/other-marker" ;;
    wrong-owner) printf '16 TeslaCam/clip.mp4\n' > "$toc"; chmod 0600 "$toc"; BAD_MARKER_OWNER=1 ;;
    stat-error) printf '16 TeslaCam/clip.mp4\n' > "$toc"; chmod 0600 "$toc"; MARKER_STAT_ERROR=1 ;;
    list-error) MARKER_FIND_ERROR=1 ;;
  esac
  expect_status 1 bash "$manager" 1
  [ -f "$SNAPSHOTS_ROOT/snap-000001/snap.bin" ] || fail 'invalid completion marker was treated as a disposable incomplete copy'
  [ ! -s "$CALLS" ] || fail 'invalid completion marker reached release'
done

new_case symlink-image
mkdir "$SNAPSHOTS_ROOT/snap-000001"
touch "$BACKINGFILES_ROOT/unrelated-image"
ln -s "$BACKINGFILES_ROOT/unrelated-image" "$SNAPSHOTS_ROOT/snap-000001/snap.bin"
expect_status 1 bash "$manager" 1
[ -L "$SNAPSHOTS_ROOT/snap-000001/snap.bin" ] || fail 'symlink image was released'
[ -f "$BACKINGFILES_ROOT/unrelated-image" ] || fail 'symlink image target was removed'
[ ! -s "$CALLS" ] || fail 'symlink image reached release'

new_case active-creation-lock
snapshot snap-000001
exec {held}< "$SNAPSHOTS_ROOT"
flock -n "$held"
expect_status 99 bash "$manager" 1
[ ! -s "$CALLS" ] || fail 'cleanup crossed a held creation/index lock'
exec {held}<&-

for state in failed-unmount-still-mounted successful-unmount-still-mounted nested-mounted \
  inspection-error inspection-exit-one inspection-empty inspection-no-root inspection-malformed \
  associated-loop loop-inspection-error escaped-mountpoint
do
  new_case "$state"
  snapshot snap-000001
  mkdir -p "$MUTABLE_TESLACAM/SavedClips/empty-event"
  link="$MUTABLE_TESLACAM/SavedClips/clip.mp4"
  ln -s "$SNAPSHOTS_ROOT/snap-000001/mnt/TeslaCam/SavedClips/clip.mp4" "$link"
  case "$state" in
    failed-unmount-still-mounted) UNMOUNT_STATUS=32; MOUNT_TABLE_MODE=mounted ;;
    successful-unmount-still-mounted) MOUNT_TABLE_MODE=mounted ;;
    nested-mounted) MOUNT_TABLE_MODE=nested ;;
    inspection-error) FINDMNT_STATUS=2 ;;
    inspection-exit-one) FINDMNT_STATUS=1 ;;
    inspection-empty) MOUNT_TABLE_MODE=empty ;;
    inspection-no-root) MOUNT_TABLE_MODE=no-root ;;
    inspection-malformed) MOUNT_TABLE_MODE=malformed ;;
    associated-loop) LOOP_ASSOCIATED=1 ;;
    loop-inspection-error) LOSETUP_STATUS=2 ;;
    escaped-mountpoint)
      SNAPSHOT_MOUNT_ROOT="$BACKINGFILES_ROOT/mount path"
      MOUNT_TABLE_MODE=escaped
      ;;
  esac
  expect_status 75 bash "$RELEASE_SNAPSHOT" snap-000001
  [ -f "$SNAPSHOTS_ROOT/snap-000001/snap.bin" ] || fail 'unsafe release removed the image'
  [ -L "$link" ] || fail 'unsafe release removed a view link'
  [ -d "$MUTABLE_TESLACAM/SavedClips/empty-event" ] || fail 'unsafe release pruned a directory'
done

for unmount_status in 0 32
do
  new_case "verified-unmounted-$unmount_status"
  snapshot snap-000001
  UNMOUNT_STATUS="$unmount_status"
  expect_status 0 bash "$RELEASE_SNAPSHOT" snap-000001
  [ ! -e "$SNAPSHOTS_ROOT/snap-000001" ] || fail 'verified unmounted image not released'
  [ "$(<"$CALLS")" = $'umount\nfindmnt\nlosetup' ] || fail 'release omitted a required absence check'
done

echo 'Snapshot retention and verified-release tests passed'
