#!/bin/bash -eu

printf "Forcing archiveloop to sync by pretending to take archive host offline and back online.\n"
printf "Setting archive unreachable..\n"
marker="${FORCE_SYNC_MARKER:-/tmp/archive_is_unreachable}"
if ! touch "$marker"
then
  printf "Something went wrong!  Error %d\nAborting.\n" "$?" 1>&2
  exit 1
fi
timeout_seconds="${FORCE_SYNC_TIMEOUT_SECONDS:-120}"
case "$timeout_seconds" in
  '' | *[!0-9]*)
    printf "Invalid FORCE_SYNC_TIMEOUT_SECONDS: %s\n" "$timeout_seconds" >&2
    exit 2
    ;;
esac
deadline=$((SECONDS + timeout_seconds))
while [[ -f "$marker" ]]
do
  if ((SECONDS >= deadline))
  then
    printf "Timed out waiting for archiveloop; the sync request remains queued.\n" >&2
    exit 124
  fi
  printf "Waiting for archiveloop to see canary file..\n"
  sleep 5
done
printf "Done!  archiveloop process should now start its sync process automagically as soon as it sees the archive.\n"
