#!/bin/bash -eu

BACKINGFILES_ROOT="${BACKINGFILES_ROOT:-/backingfiles}"
SNAPSHOTS_ROOT="${SNAPSHOTS_ROOT:-$BACKINGFILES_ROOT/snapshots}"
SNAPSHOT_MOUNT_ROOT="${SNAPSHOT_MOUNT_ROOT:-/tmp/snapshots}"
SNAPSHOT_FINDMNT_COMMAND="${SNAPSHOT_FINDMNT_COMMAND:-findmnt}"
MUTABLE_TESLACAM="${MUTABLE_TESLACAM:-/mutable/TeslaCam}"
SNAPSHOT_POLICY_HELPER="${SNAPSHOT_POLICY_HELPER:-/root/bin/snapshot_contains_encrypted_clips.sh}"
readonly BACKINGFILES_ROOT SNAPSHOTS_ROOT SNAPSHOT_MOUNT_ROOT
readonly SNAPSHOT_FINDMNT_COMMAND MUTABLE_TESLACAM
readonly SNAPSHOT_POLICY_HELPER

NAME=$(basename -- "$1")

if [[ ! "$NAME" =~ ^snap-[0-9]{6}$ ]]
then
  log "invalid snapshot name"
  exit 64
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run/snapshot_lock.sh
source "$script_dir/snapshot_lock.sh"
acquire_snapshot_lock

policy_status=0
env SNAPSHOTS_ROOT="$SNAPSHOTS_ROOT" \
  SNAPSHOT_MOUNT_ROOT="$SNAPSHOT_MOUNT_ROOT" \
  SNAPSHOT_FINDMNT_COMMAND="$SNAPSHOT_FINDMNT_COMMAND" \
  "$SNAPSHOT_POLICY_HELPER" "$NAME" || policy_status=$?
case "$policy_status" in
  0)
    log "refusing to automatically release $NAME because EncryptedClips is present"
    exit 75
    ;;
  1)
    ;;
  *)
    log "refusing to automatically release $NAME because its EncryptedClips status is unknown"
    exit 75
    ;;
esac

# Select only links to this exact snapshot before resolving any target. Reading
# every historical link with separate readlink/realpath processes made each
# release increasingly slow as history grew. find emits both fields in one
# walk; unrelated links never trigger a resolver or an autofs mount.
obsolete_links=()
if [ -d "$MUTABLE_TESLACAM" ] && [ ! -L "$MUTABLE_TESLACAM" ]
then
  while IFS= read -r -d '' mutable_link && IFS= read -r -d '' link_target
  do
    case "$mutable_link" in
      */EncryptedClips | */EncryptedClips/*)
        continue
        ;;
    esac
    case "$link_target" in
      */EncryptedClips | */EncryptedClips/* | */../* | */./*)
        continue
        ;;
      "$SNAPSHOTS_ROOT/$NAME/mnt/"* | "$SNAPSHOT_MOUNT_ROOT/$NAME/"*)
        ;;
      *)
        continue
        ;;
    esac
    # Classify aliases while the read-only snapshot still exists. Do not follow
    # arbitrary relative/custom links and never inspect recording contents.
    resolved_link=$(realpath -e -- "$mutable_link" 2> /dev/null || true)
    case "$resolved_link" in
      */EncryptedClips | */EncryptedClips/*)
        continue
        ;;
    esac
    obsolete_links+=("$mutable_link")
  done < <(find "$MUTABLE_TESLACAM" -name EncryptedClips -prune -o \
    -type l -printf '%p\0%l\0')
fi

log "releasing snapshot $SNAPSHOTS_ROOT/$NAME"
IMAGE="$SNAPSHOTS_ROOT/$NAME/snap.bin"
umount "$IMAGE" || true

# Delete the snapshot folders, then unlink obsolete view entries in bounded
# batches. Keep the directory lock through both operations.
rm -rf -- "$SNAPSHOTS_ROOT/$NAME"
for ((link_index=0; link_index<${#obsolete_links[@]}; link_index+=256))
do
  rm -f -- "${obsolete_links[@]:link_index:256}"
done

if [ -d "$MUTABLE_TESLACAM" ] && [ ! -L "$MUTABLE_TESLACAM" ]
then
  # Delete empty standard-view folders, but never an EncryptedClips directory
  # or anything below one, including legacy/custom mutable paths.
  find "$MUTABLE_TESLACAM" -depth -mindepth 2 \
    ! -path '*/EncryptedClips' ! -path '*/EncryptedClips/*' \
    -type d -empty -delete || true
fi
