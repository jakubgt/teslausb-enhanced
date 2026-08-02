#!/bin/bash -eu

exec "${ARCHIVE_RSYNC_LOCAL:-/root/bin/archive-rsync-local.sh}" "$@"
