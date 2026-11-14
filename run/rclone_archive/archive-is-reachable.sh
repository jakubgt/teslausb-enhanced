#!/bin/bash -eu

# The caller supplies the configured remote and the trusted RCLONE_FLAGS array.
# Never source configuration, interpret a command string, or use a public host
# as a substitute for checking the destination that will receive recordings.
remote_root="${1:-}"
if [ -z "$remote_root" ] || [[ "$remote_root" != *:* ]] ||
   [[ "$remote_root" == *$'\n'* || "$remote_root" == *$'\r'* ]]
then
  exit 64
fi
shift

# A shallow, read-only directory listing uses the configured backend and its
# credentials. Empty directories (including new object-store prefixes) succeed.
# Listing access does not establish write permission, quota, or transfer success;
# the archive copy and destination verification still make those decisions.
# Force bounded retry/time settings after optional trusted backend flags. The
# outer deadline also bounds DNS, backend initialization and low-level retries.
# Suppress backend diagnostics: URLs, account names or credentials may occur in
# errors. The caller logs a fixed explanation rather than a raw provider error.
exec "${ARCHIVE_TIMEOUT_BIN:-timeout}" --signal=TERM --kill-after=2s 15s \
  "${ARCHIVE_RCLONE_BIN:-rclone}" --config /root/.config/rclone/rclone.conf \
  lsf "$@" --dirs-only --recursive=false --max-depth=1 --fast-list=false \
  --retries=1 --low-level-retries=1 --contimeout=5s --timeout=10s \
  --ask-password=false --log-level=ERROR -- "$remote_root" > /dev/null 2>&1
