#!/bin/bash -eu

BACKINGFILES_ROOT="${BACKINGFILES_ROOT:-/backingfiles}"
SNAPSHOTS_ROOT="${SNAPSHOTS_ROOT:-$BACKINGFILES_ROOT/snapshots}"
SNAPSHOT_MOUNT_ROOT="${SNAPSHOT_MOUNT_ROOT:-/tmp/snapshots}"
SNAPSHOT_FINDMNT_COMMAND="${SNAPSHOT_FINDMNT_COMMAND:-findmnt}"
SNAPSHOT_LOSETUP_COMMAND="${SNAPSHOT_LOSETUP_COMMAND:-losetup}"
MUTABLE_TESLACAM="${MUTABLE_TESLACAM:-/mutable/TeslaCam}"
SNAPSHOT_POLICY_HELPER="${SNAPSHOT_POLICY_HELPER:-/root/bin/snapshot_contains_encrypted_clips.sh}"
readonly BACKINGFILES_ROOT SNAPSHOTS_ROOT SNAPSHOT_MOUNT_ROOT
readonly SNAPSHOT_FINDMNT_COMMAND SNAPSHOT_LOSETUP_COMMAND MUTABLE_TESLACAM
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
acquire_snapshot_lock || exit "$?"

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

IMAGE="$SNAPSHOTS_ROOT/$NAME/snap.bin"
unmount_status=0
umount "$IMAGE" || unmount_status=$?

# A filtered findmnt failure is ambiguous: exit 1 means both "no match" and
# an inspection error. Require a successful complete kernel mount table, then
# compare text without statting the autofs key and triggering a new mount.
mount_targets=
if ! mount_targets=$("$SNAPSHOT_FINDMNT_COMMAND" --kernel --raw --noheadings --output TARGET)
then
  log "refusing to release $NAME because mount inspection failed (unmount=$unmount_status)"
  exit 75
fi
root_seen=false
while IFS= read -r target
do
  case "$target" in
    /*) ;;
    *)
      log "refusing to release $NAME because mount inspection is incomplete"
      exit 75
      ;;
  esac
  target=$(printf '%b' "$target")
  [ "$target" != / ] || root_seen=true
  case "$target" in
    "$SNAPSHOT_MOUNT_ROOT/$NAME" | "$SNAPSHOT_MOUNT_ROOT/$NAME/"* | \
    "$SNAPSHOTS_ROOT/$NAME" | "$SNAPSHOTS_ROOT/$NAME/"*)
      log "refusing to release $NAME because its view remains mounted (unmount=$unmount_status)"
      exit 75
      ;;
  esac
done <<< "$mount_targets"
if [ "$root_seen" != true ]
then
  log "refusing to release $NAME because mount inspection is incomplete"
  exit 75
fi
# Also refuse a backing-image loop association, including a mount at an
# unexpected alias. Successful empty output establishes absence; errors do not.
loop_devices=
if ! loop_devices=$("$SNAPSHOT_LOSETUP_COMMAND" --list --associated "$IMAGE" \
    --noheadings --output NAME)
then
  log "refusing to release $NAME because loop inspection failed"
  exit 75
fi
if [ -n "$loop_devices" ]
then
  log "refusing to release $NAME because its image still has a loop association"
  exit 75
fi

log "releasing snapshot $SNAPSHOTS_ROOT/$NAME"
# Delete the snapshot folders, then unlink obsolete view entries in bounded
# batches. Keep the directory lock through both operations.
rm -rf -- "${SNAPSHOTS_ROOT:?}/${NAME:?}"
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

# Publish completion only after required removals. Inspection above must have
# succeeded before any snapshot/view removal; logging itself is best effort.
released_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || released_at=
log "released snapshot $NAME${released_at:+ at $released_at}" || true
