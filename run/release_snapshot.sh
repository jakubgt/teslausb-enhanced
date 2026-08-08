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

log "releasing snapshot $SNAPSHOTS_ROOT/$NAME"
IMAGE="$SNAPSHOTS_ROOT/$NAME/snap.bin"
umount "$IMAGE" || true

# delete the snapshot folders
rm -rf -- "$SNAPSHOTS_ROOT/$NAME"

# Delete obsolete links, except literal or aliased EncryptedClips paths. Link
# targets are resolved only to classify their directory path; contents are not
# opened.
if [ -d "$MUTABLE_TESLACAM" ] && [ ! -L "$MUTABLE_TESLACAM" ]
then
  while IFS= read -r -d '' mutable_link
  do
    case "$mutable_link" in
      */EncryptedClips | */EncryptedClips/*)
        continue
        ;;
    esac
    resolved_link=$(realpath -e -- "$mutable_link" 2> /dev/null || true)
    case "$resolved_link" in
      */EncryptedClips | */EncryptedClips/*)
        continue
        ;;
    esac
    link_target=$(readlink -- "$mutable_link" || true)
    case "$link_target" in
      */"$NAME"/*)
        rm -f -- "$mutable_link"
        ;;
    esac
  done < <(find "$MUTABLE_TESLACAM" -name EncryptedClips -prune -o \
    -type l -print0)

  # Delete empty standard-view folders, but never an EncryptedClips directory
  # or anything below one, including legacy/custom mutable paths.
  find "$MUTABLE_TESLACAM" -depth -mindepth 2 \
    ! -path '*/EncryptedClips' ! -path '*/EncryptedClips/*' \
    -type d -empty -exec rmdir "{}" \; || true
fi
