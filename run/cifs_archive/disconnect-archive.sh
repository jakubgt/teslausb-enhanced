#!/bin/bash -eu

# Unmount the archive. Without this, the archive mounts can get into a
# state where the archive is reachable via the network, appears to be
# mounted, but the mount is inoperable and any attempt to access it
# results in a "host is down" message.
# Run this in the background, since unmounting can hang, which would
# block a return to archiveloop.

unmount_if_set() {
  local mount_point=$1
  if [ -n "$mount_point" ]
  then
    if timeout 30 umount -f -l "$mount_point"
    then
      log "$mount_point unmounted."
    else
      log "$mount_point failed to unmount!"
    fi
  fi
}

{
  unmount_if_set "${ARCHIVE_MOUNT:-}"
  unmount_if_set "${MUSIC_ARCHIVE_MOUNT:-}"
} &
