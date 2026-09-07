#!/bin/bash -eu

# Return 0 when a snapshot view contains a non-empty TeslaCam/EncryptedClips,
# 1 when a mounted/readable view is confirmed clear, and 2 when the result is
# unknown. Directory entries are checked, but clip contents are never opened.

if [ "$#" -ne 1 ]
then
  echo "usage: $0 SNAPSHOT_NAME" >&2
  exit 2
fi

snapshots_root="${SNAPSHOTS_ROOT:-/backingfiles/snapshots}"
snapshot_mount_root="${SNAPSHOT_MOUNT_ROOT:-/tmp/snapshots}"
snapshot_findmnt_command="${SNAPSHOT_FINDMNT_COMMAND:-findmnt}"
script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
path_status_helper="${TESLAUSB_ENCRYPTED_PATH_STATUS_HELPER:-$script_dir/encrypted_clips_path_status.sh}"
snapshot_name="$1"
case "$snapshot_name" in
  snap-[0-9][0-9][0-9][0-9][0-9][0-9])
    ;;
  *)
    echo "invalid snapshot name: $snapshot_name" >&2
    exit 2
    ;;
esac

snapshot_dir="$snapshots_root/$snapshot_name"
snapshot_image="$snapshot_dir/snap.bin"
snapshot_view="$snapshot_dir/mnt"
if [ -L "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ] ||
   [ -L "$snapshot_image" ] || [ ! -f "$snapshot_image" ] ||
   [ ! -r "$snapshot_image" ]
then
  exit 2
fi

if [ -L "$snapshot_view" ]
then
  expected_view="$snapshot_mount_root/$snapshot_name"
  [ "$(readlink -- "$snapshot_view")" = "$expected_view" ] || exit 2
  snapshot_view="$expected_view"
elif [ ! -d "$snapshot_view" ]
then
  # Newly-created and some legacy snapshots may not have their convenience
  # link yet. Addressing the guarded autofs key is enough to obtain a
  # read-only view without modifying the snapshot directory.
  snapshot_view="$snapshot_mount_root/$snapshot_name"
fi

encrypted_status=0
"$path_status_helper" "$snapshot_view/TeslaCam/EncryptedClips" || encrypted_status=$?
case "$encrypted_status" in
  0)
    exit 0
    ;;
  1)
    ;;
  *)
    exit 2
    ;;
esac

# Seeing TeslaCam proves the snapshot view was mounted/readable. If autofs or
# the image failed, fail closed instead of treating the empty mount as clear.
if [ -d "$snapshot_view/TeslaCam" ]
then
  if "$snapshot_findmnt_command" --mountpoint "$snapshot_view" > /dev/null 2>&1
  then
    exit 1
  fi
fi
exit 2
