#!/bin/sh

# Classify one TeslaCam/EncryptedClips path without opening clip contents.
# Return 0 when the path is a symlink, a non-directory entry, or a directory
# containing at least one entry; 1 when it is absent or an empty directory; and
# 2 when its state cannot be determined safely.

set -u

if [ "$#" -ne 1 ]
then
  echo "usage: $0 ENCRYPTED_CLIPS_PATH" >&2
  exit 2
fi

candidate="$1"

# Never follow a link at the policy boundary, including a broken link or one
# that currently resolves to an empty directory.
if [ -L "$candidate" ]
then
  exit 0
fi

if [ ! -e "$candidate" ]
then
  exit 1
fi

# An unexpected file/device at the reserved path is protected conservatively.
if [ ! -d "$candidate" ]
then
  exit 0
fi

entry_marker=
find_status=0
entry_marker=$(find -- "$candidate" -mindepth 1 -maxdepth 1 \
  -printf x -quit 2> /dev/null) || find_status=$?
if [ "$find_status" -ne 0 ]
then
  exit 2
fi

if [ -n "$entry_marker" ]
then
  exit 0
fi
exit 1
