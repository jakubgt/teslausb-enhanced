#!/bin/bash -eu

set -o pipefail

archive_common="${ARCHIVE_COMMON_SH:-/root/bin/archive-common.sh}"
# shellcheck source=run/archive-common.sh
source "$archive_common"

workdir=$(mktemp -d "${ARCHIVE_WORK_ROOT:-/tmp}/teslausb-rsync-archive.XXXXXX")
readonly workdir
trap 'rm -rf -- "$workdir"' EXIT
trap 'exit 1' HUP INT TERM

remote_root="$RSYNC_USER@$RSYNC_SERVER:$RSYNC_PATH"
remote_shell="${RSYNC_REMOTE_SHELL:-ssh -o ConnectTimeout=${RSYNC_SSH_CONNECT_TIMEOUT:-15} -o ServerAliveInterval=30 -o ServerAliveCountMax=4}"
pair=0
while [ "$#" -gt 0 ]
do
  if [ "$#" -lt 2 ]
  then
    printf 'archive-clips received an incomplete source/list pair\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 64
  fi
  source_root="$1"
  file_list="$2"
  shift 2
  pair=$((pair + 1))

  manifest="$workdir/manifest-$pair.tsv"
  archive_manifest_create "$source_root" "$file_list" "$manifest"
  read -r manifest_files _ < <(archive_manifest_stats "$manifest")
  if [ "$manifest_files" -eq 0 ]
  then
    continue
  fi

  rsync_status=0
  "${ARCHIVE_RSYNC_BIN:-rsync}" -avhRL --timeout="${ARCHIVE_RSYNC_TIMEOUT:-60}" \
    --rsh="$remote_shell" \
    --no-perms --omit-dir-times --stats --ignore-missing-args \
    --log-file="$workdir/rsync-command.log" --files-from="$file_list" \
    "$source_root/" "$remote_root" > "$workdir/rsync-output.log" 2>&1 || rsync_status=$?
  if [ "$rsync_status" -ne 0 ] && [ "$rsync_status" -ne 24 ]
  then
    cat "$workdir/rsync-command.log" "$workdir/rsync-output.log" > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit "$rsync_status"
  fi

  if ! archive_manifest_verify_sources "$source_root" "$manifest"
  then
    printf 'Source changed while rsync was transferring; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  # A checksum dry-run asks the remote rsync to read every destination file.
  # Any proposed change means destination contents are not yet identical.
  if verification=$("${ARCHIVE_RSYNC_BIN:-rsync}" -rLcni \
      --timeout="${ARCHIVE_RSYNC_TIMEOUT:-60}" --rsh="$remote_shell" \
      --no-perms --no-owner --no-group \
      --omit-dir-times --ignore-missing-args --out-format='%i %n' \
      --files-from="$file_list" "$source_root/" "$remote_root")
  then
    if [ -n "$verification" ]
    then
      printf 'Remote destination checksum verification proposed changes:\n%s\n' "$verification" \
        > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
      exit 74
    fi
  else
    printf 'Remote destination checksum verification failed\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  if ! archive_manifest_verify_sources "$source_root" "$manifest"
  then
    printf 'Source changed during remote verification; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  manifest_name=$(archive_manifest_name "$manifest" "$pair")
  manifest_stage="$workdir/.teslausb-manifests"
  mkdir -p -- "$manifest_stage"
  cp -- "$manifest" "$manifest_stage/$manifest_name"
  if ! "${ARCHIVE_RSYNC_BIN:-rsync}" -a --timeout="${ARCHIVE_RSYNC_TIMEOUT:-60}" \
      --rsh="$remote_shell" \
      "$manifest_stage/" "$remote_root/.teslausb-manifests/"
  then
    printf 'Failed to publish remote archive integrity manifest\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 73
  fi

  if ! archive_manifest_remove_sources "$source_root" "$manifest"
  then
    printf 'Destination verified, but a source changed before removal; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 75
  fi
done
