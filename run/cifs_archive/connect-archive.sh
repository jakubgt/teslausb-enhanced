#!/bin/bash -eu

function mount_if_set() {
  local mount_point=$1
  if [ -n "$mount_point" ]
  then
    if ! ensure_mountpoint_is_mounted "$mount_point"
    then
      return 1
    fi
  fi
}

mount_if_set "${ARCHIVE_MOUNT:-}"
mount_if_set "${MUSIC_ARCHIVE_MOUNT:-}"
