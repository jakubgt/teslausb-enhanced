#!/bin/bash -eu

function mount_if_set() {
  local mount_point=$1
  if [ -n "$mount_point" ]
  then
    if findmnt --mountpoint "$mount_point" > /dev/null
    then
      log "$mount_point is already mounted."
    else
      if timeout 10 mount "$mount_point" >> "$LOG_FILE" 2>&1
      then
        log "Mounted $mount_point."
      else
        log "Failed to mount $mount_point."
      fi
    fi
  fi
}

mount_if_set "${ARCHIVE_MOUNT:-}"
mount_if_set "${MUSIC_ARCHIVE_MOUNT:-}"
