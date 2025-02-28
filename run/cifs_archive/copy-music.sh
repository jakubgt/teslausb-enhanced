#!/bin/bash -eu

SRC="/mnt/musicarchive"
DST="/mnt/music"
LOG="/tmp/rsyncmusiclog.txt"

# Check that DST is the mounted disk image, not the mountpoint directory
if ! findmnt --mountpoint "$DST" > /dev/null; then
  log "$DST not mounted, skipping music sync"
  exit
fi

function do_music_sync {
  log "Syncing music from archive..."

  # Ensure SRC is accessible
  if ! timeout 5 stat "$SRC" > /dev/null; then
    log "Error: $SRC is not accessible"
    return
  fi

  # Ensure SRC is mounted
  if ! findmnt --mountpoint "$SRC" > /dev/null; then
    log "Error: $SRC not mounted"
    return
  fi

  if ! rsync -rum --no-human-readable --exclude=.fseventsd/*** --exclude=*.DS_Store --exclude=.metadata_never_index \
                --exclude="System Volume Information/***" \
                --delete --modify-window=2 --info=stats2 "$SRC/" "$DST" &> "$LOG"; then
    log "rsync failed with error $?"
  fi

  # Remove empty directories
  find "$DST" -depth -type d -empty -delete || true

  # Parse log for relevant info
  declare -i NUM_FILES_COPIED
  NUM_FILES_COPIED=$(sed -n -e 's/\(^Number of regular files transferred: \)\([[:digit:]]\+\).*/\2/p' "$LOG")
  declare -i NUM_FILES_DELETED
  NUM_FILES_DELETED=$(sed -n -e 's/\(^Number of deleted files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$LOG")
  declare -i TOTAL_FILES
  TOTAL_FILES=$(sed -n -e 's/\(^Number of files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$LOG")
  declare -i NUM_FILES_ERROR
  NUM_FILES_ERROR=$(grep -c "failed to open" "$LOG" || true)

  declare -i NUM_FILES_SKIPPED=$((TOTAL_FILES - NUM_FILES_COPIED))
  NUM_FILES_COPIED=$((NUM_FILES_COPIED - NUM_FILES_ERROR))

  # Generate sync summary message (Always log, even if nothing changed)
  if [ "$NUM_FILES_COPIED" -eq 0 ] && [ "$NUM_FILES_DELETED" -eq 0 ] && [ "$NUM_FILES_ERROR" -eq 0 ]; then
    log "Music Sync Completed: No files copied, deleted, or modified. All files are up to date."
  else
    log "Music Sync Completed: Copied $NUM_FILES_COPIED file(s), deleted $NUM_FILES_DELETED, skipped $NUM_FILES_SKIPPED, and encountered $NUM_FILES_ERROR errors."
  fi

  # Send notification **ONLY if files were copied/deleted or errors occurred**
  if [ "$NUM_FILES_COPIED" -ne 0 ] || [ "$NUM_FILES_DELETED" -ne 0 ] || [ "$NUM_FILES_ERROR" -ne 0 ]; then
    /root/bin/send-push-message "$NOTIFICATION_TITLE:" "🎵 Music Sync Completed: Copied $NUM_FILES_COPIED, Deleted $NUM_FILES_DELETED, Skipped $NUM_FILES_SKIPPED, Errors $NUM_FILES_ERROR."
  fi
}

# Start music sync
if ! do_music_sync; then
  log "Error while syncing music"
fi
