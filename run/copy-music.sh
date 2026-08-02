#!/bin/bash -eu

set -euE

SRC="${MUSIC_ARCHIVE_MOUNT:-/mnt/musicarchive}"
DST="${MUSIC_MOUNT:-/mnt/music}"
LOG="${MUSIC_SYNC_LOG:-/tmp/rsyncmusiclog.txt}"
ARCHIVE_IS_REACHABLE="${ARCHIVE_IS_REACHABLE:-/root/bin/archive-is-reachable.sh}"
monitor_pid=""
rsync_pid=""

# Check that DST is the mounted disk image, not the mountpoint directory.
if ! findmnt --mountpoint "$DST" > /dev/null
then
  log "$DST not mounted, skipping music sync"
  exit 0
fi

function connectionmonitor {
  while kill -0 "$1" &> /dev/null
  do
    for _ in {1..10}
    do
      if timeout 3 "$ARCHIVE_IS_REACHABLE" "$ARCHIVE_SERVER"
      then
        # Sleep and then continue the outer loop.
        sleep 5
        continue 2
      fi
      sleep 1
    done
    log "connection dead, stopping music rsync process $1"
    # Give rsync a chance to clean up before killing it hard.
    kill "$1" &> /dev/null || true
    sleep 2
    kill -9 "$1" || true
    return
  done
}

function stop_connection_monitor {
  if [ -n "$monitor_pid" ]
  then
    kill "$monitor_pid" &> /dev/null || true
    wait "$monitor_pid" &> /dev/null || true
    monitor_pid=""
  fi
}

function cleanup_music_sync {
  stop_connection_monitor
  if [ -n "$rsync_pid" ]
  then
    kill "$rsync_pid" &> /dev/null || true
    wait "$rsync_pid" &> /dev/null || true
    rsync_pid=""
  fi
}

trap cleanup_music_sync EXIT

function do_music_sync {
  log "Syncing music from archive..."

  # Return immediately if the archive mount can't be accessed.
  if ! timeout 5 stat "$SRC" > /dev/null
  then
    log "Error: $SRC is not accessible"
    return 1
  fi

  # Check that SRC is the mounted archive and not the empty mountpoint
  # directory, since the latter would cause all music to be deleted from DST.
  if ! findmnt --mountpoint "$SRC" > /dev/null
  then
    log "Error: $SRC not mounted"
    return 1
  fi

  local rsync_status=0
  rsync -rum --timeout="${MUSIC_RSYNC_TIMEOUT:-60}" \
    --no-human-readable --exclude='.fseventsd/***' --exclude='*.DS_Store' --exclude='.metadata_never_index' \
    --exclude="System Volume Information/***" \
    --delete --modify-window=2 --info=stats2 "$SRC/" "$DST" &> "$LOG" &
  rsync_pid=$!
  connectionmonitor "$rsync_pid" &
  monitor_pid=$!
  if wait "$rsync_pid"
  then
    rsync_status=0
  else
    rsync_status=$?
  fi
  rsync_pid=""

  stop_connection_monitor

  if [ "$rsync_status" -ne 0 ]
  then
    log "rsync failed with error $rsync_status"
    return "$rsync_status"
  fi

  # Remove empty directories.
  find "$DST" -depth -type d -empty -delete || true

  # Parse the log for relevant info.
  local -i NUM_FILES_COPIED=0
  NUM_FILES_COPIED=$(sed -n -e 's/\(^Number of regular files transferred: \)\([[:digit:]]\+\).*/\2/p' "$LOG")
  local -i NUM_FILES_DELETED=0
  NUM_FILES_DELETED=$(sed -n -e 's/\(^Number of deleted files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$LOG")
  local -i TOTAL_FILES=0
  TOTAL_FILES=$(sed -n -e 's/\(^Number of files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$LOG")
  local -i NUM_FILES_ERROR=0
  NUM_FILES_ERROR=$(grep -c "failed to open" "$LOG" || true)

  local -i NUM_FILES_SKIPPED=$((TOTAL_FILES-NUM_FILES_COPIED))
  NUM_FILES_COPIED=$((NUM_FILES_COPIED-NUM_FILES_ERROR))

  local message="Copied $NUM_FILES_COPIED music file(s), deleted $NUM_FILES_DELETED, skipped $NUM_FILES_SKIPPED previously-copied files, and encountered $NUM_FILES_ERROR errors."

  if [ "$NUM_FILES_COPIED" -ne 0 ] || [ "$NUM_FILES_DELETED" -ne 0 ] || [ "$NUM_FILES_ERROR" -ne 0 ]
  then
    /root/bin/send-push-message "$NOTIFICATION_TITLE:" "$message"
  else
    log "$message"
  fi
}

function music_sync_error {
  local status=$?
  trap - ERR
  log "Error while syncing music" || true
  exit "$status"
}

trap music_sync_error ERR
do_music_sync
trap - ERR
