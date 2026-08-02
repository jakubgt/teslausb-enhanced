#!/bin/bash -eu

unmount_if_set() {
  local mount_point=$1
  if [ -n "$mount_point" ]
  then
    if findmnt --mountpoint "$mount_point" > /dev/null
    then
      if timeout 10 umount -f -l "$mount_point" >> "$LOG_FILE" 2>&1
      then
        log "Unmounted $mount_point."
      else
        log "Failed to unmount $mount_point."
      fi
    else
      log "$mount_point already unmounted."
    fi
  fi
}

# Keep the bounded unmounts parallel, but do not let either survive into the
# next archive iteration and race a newly connected mount.
archive_unmount_pid=
music_unmount_pid=
if [ -n "${ARCHIVE_MOUNT:-}" ]
then
  unmount_if_set "$ARCHIVE_MOUNT" &
  archive_unmount_pid=$!
fi
if [ -n "${MUSIC_ARCHIVE_MOUNT:-}" ]
then
  unmount_if_set "$MUSIC_ARCHIVE_MOUNT" &
  music_unmount_pid=$!
fi
disconnect_status=0
if [ -n "$archive_unmount_pid" ] && ! wait "$archive_unmount_pid"
then
  disconnect_status=1
fi
if [ -n "$music_unmount_pid" ] && ! wait "$music_unmount_pid"
then
  disconnect_status=1
fi
exit "$disconnect_status"
