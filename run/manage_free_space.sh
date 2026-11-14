#!/bin/bash -eu

set -o pipefail

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

function snapshot_completion_status {
  # Return 0 for a finalized, protected marker, 1 for a missing marker, and 2
  # when completion is unknown. Listing the entry first distinguishes absence
  # from a failed stat, and a symlink must never stand in for a completed TOC.
  local snapshot_dir="$1"
  local marker
  local marker_info
  local owner links mode
  if ! marker=$(find "$snapshot_dir" -mindepth 1 -maxdepth 1 \
      -name snap.bin.toc -printf '%f\n')
  then
    return 2
  fi
  [ -n "$marker" ] || return 1
  if [ "$marker" != snap.bin.toc ] || [ -L "$snapshot_dir/$marker" ] ||
     [ ! -f "$snapshot_dir/$marker" ] || [ ! -s "$snapshot_dir/$marker" ]
  then
    return 2
  fi
  # An empty listing may represent an empty image, but it does not establish
  # a completed recording copy. Retain it without superseding the last
  # nonempty completed snapshot.
  marker_info=$(stat --format='%u:%h:%a' -- "$snapshot_dir/$marker") || return 2
  IFS=: read -r owner links mode <<< "$marker_info"
  if [ "$owner" != "$EUID" ] || [ "$links" != 1 ] ||
     [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 0022) != 0 ))
  then
    return 2
  fi
  return 0
}

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
    local snapshot_dirs snapshot_dir snapshot_image snapshot_name completion_status policy_status
    local newest_complete=
    local -a incomplete=() completed=()
    if ! snapshot_dirs=$(find "$SNAPSHOTS_ROOT" -mindepth 1 -maxdepth 1 \
        -type d -name 'snap-*' -print | LC_ALL=C sort)
    then
      log "Warning: unable to inspect snapshot retention safely; stopping low-space rotation."
      exit 1
    fi
    while IFS= read -r snapshot_dir
    do
      snapshot_name=${snapshot_dir##*/}
      [[ "$snapshot_name" =~ ^snap-[0-9]{6}$ ]] || continue
      snapshot_image="$snapshot_dir/snap.bin"
      if [ -L "$snapshot_image" ] || [ ! -f "$snapshot_image" ]
      then
        log "low-space rotation is preserving $snapshot_name because its image is unknown"
        continue
      fi
      completion_status=0
      snapshot_completion_status "$snapshot_dir" || completion_status=$?
      case "$completion_status" in
        0)
          completed+=("$snapshot_dir")
          newest_complete="$snapshot_dir"
          ;;
        1)
          incomplete+=("$snapshot_dir")
          ;;
        *)
          log "low-space rotation is preserving $snapshot_name because its completion marker is unknown"
          ;;
      esac
    done <<< "$snapshot_dirs"
    if [ "${#incomplete[@]}" -eq 0 ] && [ "${#completed[@]}" -eq 0 ]
    then
      log "Warning: low space, but no snapshot has a known retention state."
      exit 1
    fi

    local oldest=
    # A failed/incomplete copy must not cause the last completed snapshot to
    # be rotated away. Cleanup holds the same lock as creation and indexing,
    # so these incomplete candidates cannot be active snapshot writers.
    for snapshot_dir in "${incomplete[@]}" "${completed[@]}"
    do
      if [ "$snapshot_dir" = "$newest_complete" ]
      then
        log "low-space rotation is preserving the newest completed snapshot ${snapshot_dir##*/}"
        continue
      fi
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
    done
    if [ -z "$oldest" ]
    then
      log "Warning: low space, but no eligible snapshot is confirmed clear of EncryptedClips; manual storage review is required."
      exit 1
    fi
    log "low space, deleting $oldest"
    if ! "$RELEASE_SNAPSHOT" "$oldest"
    then
      log "Warning: snapshot release failed for $oldest; stopping low-space rotation."
      exit 1
    fi
    if [ -e "$oldest" ] || [ -L "$oldest" ]
    then
      log "Warning: released snapshot still exists; stopping low-space rotation."
      exit 1
    fi
  done
}

# This will normally be called with a value of "10G + 3% of total space",
# but default to 20G if not specified
manage_free_space "${1:-21474836480}"
