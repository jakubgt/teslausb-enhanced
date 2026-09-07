#!/bin/bash -eu

if [ "${BASH_SOURCE[0]}" != "$0" ]
then
  echo "${BASH_SOURCE[0]} must be executed, not sourced"
  return 1 # shouldn't use exit when sourced
fi

BACKINGFILES_ROOT="${BACKINGFILES_ROOT:-/backingfiles}"
SNAPSHOTS_ROOT="${SNAPSHOTS_ROOT:-$BACKINGFILES_ROOT/snapshots}"
SNAPSHOT_MOUNT_ROOT="${SNAPSHOT_MOUNT_ROOT:-/tmp/snapshots}"
SNAPSHOT_FINDMNT_COMMAND="${SNAPSHOT_FINDMNT_COMMAND:-findmnt}"
SNAPSHOT_POLICY_HELPER="${SNAPSHOT_POLICY_HELPER:-/root/bin/snapshot_contains_encrypted_clips.sh}"
RELEASE_SNAPSHOT="${RELEASE_SNAPSHOT:-/root/bin/release_snapshot.sh}"
readonly BACKINGFILES_ROOT SNAPSHOTS_ROOT SNAPSHOT_MOUNT_ROOT
readonly SNAPSHOT_FINDMNT_COMMAND SNAPSHOT_POLICY_HELPER RELEASE_SNAPSHOT

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=run/snapshot_lock.sh
source "$script_dir/snapshot_lock.sh"
acquire_snapshot_lock || exit "$?"

function manage_free_space {
  # Try to make free space equal to 10 GB plus three percent of the total
  # available space. This should be enough to hold the next hour of
  # recordings without completely filling up the filesystem.
  # todo: this could be put in a background task and with a lower free
  # space requirement, to delete old snapshots just before running out
  # of space and thus make better use of space
  local reserve="$1"
  while true
  do
    local freespace
    freespace=$(eval "$(stat --file-system --format="echo \$((%f*%S))" "$BACKINGFILES_ROOT/cam_disk.bin")")
    if [ "$freespace" -gt "$reserve" ]
    then
      exit 0
    fi
    if ! stat "$SNAPSHOTS_ROOT"/snap-*/snap.bin > /dev/null 2>&1
    then
      log "Warning: low space for new snapshots, but no snapshots exist."
      log "Please use a larger storage medium or reduce CAM_SIZE"
      exit 1
    fi
    # if there's only one snapshot then we likely just took it, so don't immediately delete it
    if [ "$(find "$SNAPSHOTS_ROOT" -name snap.bin 2> /dev/null | wc -l)" -lt 2 ]
    then
      # there's only one snapshot and yet we're low on space
      log "Warning: low space for new snapshots, but only one snapshot exists."
      log "Please use a larger storage medium or reduce CAM_SIZE"
      exit 1
    fi

    oldest=
    while IFS= read -r snapshot_dir
    do
      snapshot_name=$(basename -- "$snapshot_dir")
      policy_status=0
      env SNAPSHOTS_ROOT="$SNAPSHOTS_ROOT" \
        SNAPSHOT_MOUNT_ROOT="$SNAPSHOT_MOUNT_ROOT" \
        SNAPSHOT_FINDMNT_COMMAND="$SNAPSHOT_FINDMNT_COMMAND" \
        "$SNAPSHOT_POLICY_HELPER" "$snapshot_name" || policy_status=$?
      case "$policy_status" in
        0)
          log "low-space rotation is preserving $snapshot_name because EncryptedClips is present"
          ;;
        1)
          oldest="$snapshot_dir"
          break
          ;;
        *)
          log "low-space rotation is preserving $snapshot_name because its EncryptedClips status is unknown"
          ;;
      esac
    done < <(find "$SNAPSHOTS_ROOT" -mindepth 1 -maxdepth 1 -type d \
      -name 'snap-*' -print | LC_ALL=C sort)
    if [ -z "$oldest" ]
    then
      log "Warning: low space, but no snapshot is confirmed clear of EncryptedClips."
      exit 1
    fi
    log "low space, deleting $oldest"
    if ! "$RELEASE_SNAPSHOT" "$oldest"
    then
      log "Warning: snapshot release failed for $oldest; stopping low-space rotation."
      exit 1
    fi
  done
}

# This will normally be called with a value of "10G + 3% of total space",
# but default to 20G if not specified
manage_free_space "${1:-21474836480}"
