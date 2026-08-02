#!/bin/bash -eu

export ARCHIVE_RSYNC_NO_OWNER=true
exec "${ARCHIVE_RSYNC_LOCAL:-/root/bin/archive-rsync-local.sh}" "$@"
