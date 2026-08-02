#!/bin/bash -eu

set -o pipefail

# CIFS and NFS share the same transfer implementation. NFS sets
# ARCHIVE_RSYNC_NO_OWNER=true because root-squashed exports cannot preserve it.
archive_common="${ARCHIVE_COMMON_SH:-/root/bin/archive-common.sh}"
# shellcheck source=run/archive-common.sh
source "$archive_common"

workdir=$(mktemp -d "${ARCHIVE_WORK_ROOT:-/tmp}/teslausb-archive.XXXXXX")
readonly workdir
transfer_pid=
monitor_pid=
archive_temp_root="$ARCHIVE_MOUNT/.teslausbtmp"
archive_temp_dir=
archive_temp_dir_safe=false
archive_mount_identity=

cleanup_archive_transfer() {
  if [ -n "$monitor_pid" ]
  then
    kill "$monitor_pid" &> /dev/null || true
    wait "$monitor_pid" &> /dev/null || true
  fi
  if [ -n "$transfer_pid" ]
  then
    kill "$transfer_pid" &> /dev/null || true
    wait "$transfer_pid" &> /dev/null || true
  fi
  if [ "$archive_temp_dir_safe" = true ] &&
     [ -n "$archive_temp_dir" ] &&
     [ ! -L "$archive_temp_dir" ] && [ -d "$archive_temp_dir" ] &&
     same_archive_mount
  then
    rm -rf -- "$archive_temp_dir" || true
  fi
  rm -rf -- "$workdir"
}
trap cleanup_archive_transfer EXIT
trap 'exit 1' HUP INT TERM

connection_monitor() {
  local watched_pid="$1"

  while kill -0 "$watched_pid" &> /dev/null
  do
    for _ in {1..5}
    do
      if timeout 6 "${ARCHIVE_IS_REACHABLE:-/root/bin/archive-is-reachable.sh}" "$ARCHIVE_SERVER"
      then
        sleep 5
        continue 2
      fi
      sleep 1
    done
    log "connection dead, stopping archive rsync process $watched_pid"
    kill "$watched_pid" &> /dev/null || true
    sleep 2
    kill -9 "$watched_pid" &> /dev/null || true
    return
  done
}

stop_monitor() {
  if [ -n "$monitor_pid" ]
  then
    kill "$monitor_pid" &> /dev/null || true
    wait "$monitor_pid" &> /dev/null || true
    monitor_pid=
  fi
}

run_monitored_rsync() {
  local status

  "${ARCHIVE_RSYNC_BIN:-rsync}" "$@" &
  transfer_pid=$!
  connection_monitor "$transfer_pid" &
  monitor_pid=$!
  if wait "$transfer_pid"
  then
    status=0
  else
    status=$?
  fi
  transfer_pid=
  stop_monitor
  return "$status"
}

write_archive_error() {
  local message="$1"
  local error_file="${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
  local error_dir
  local tmp

  error_dir=$(dirname -- "$error_file")
  mkdir -p -- "$error_dir"
  tmp=$(mktemp "$error_dir/.archive-error.XXXXXX")
  {
    printf '%s\n' "$message"
    [ ! -e "$workdir/rsync-command.log" ] || cat "$workdir/rsync-command.log"
    [ ! -e "$workdir/rsync-output.log" ] || cat "$workdir/rsync-output.log"
  } > "$tmp"
  mv -f -- "$tmp" "$error_file"
}

read_mount_identity() {
  local findmnt_bin="${ARCHIVE_FINDMNT_BIN:-findmnt}"
  local identity

  [ -n "${ARCHIVE_MOUNT:-}" ] && [ -d "$ARCHIVE_MOUNT" ] &&
    [ ! -L "$ARCHIVE_MOUNT" ] || return 1
  identity=$(LC_ALL=C "$findmnt_bin" --raw --noheadings \
    --mountpoint "$ARCHIVE_MOUNT" --output SOURCE,FSTYPE,MAJ:MIN) || return
  [ -n "$identity" ] && [[ "$identity" != *$'\n'* ]] || return 1
  ARCHIVE_MOUNT_IDENTITY_RESULT=$identity
}

same_archive_mount() {
  [ -n "$archive_mount_identity" ] || return 1
  read_mount_identity || return
  [ "$ARCHIVE_MOUNT_IDENTITY_RESULT" = "$archive_mount_identity" ]
}

require_same_archive_mount() {
  local phase="$1"

  if ! same_archive_mount
  then
    write_archive_error "archive mount identity changed $phase; source files were retained"
    return 76
  fi
}

archive_before_local_source_remove() {
  local source_path="$1"

  require_same_archive_mount "before removing source $source_path"
}

rsync_flags=(
  -avhRL
  --timeout="${ARCHIVE_RSYNC_TIMEOUT:-60}"
  --no-perms
  --omit-dir-times
  --stats
  --ignore-missing-args
)
if [ "${ARCHIVE_RSYNC_NO_OWNER:-false}" = "true" ]
then
  rsync_flags+=(--no-o --no-g)
fi
if ! read_mount_identity
then
  write_archive_error "$ARCHIVE_MOUNT is not a mounted archive filesystem"
  exit 76
fi
archive_mount_identity=$ARCHIVE_MOUNT_IDENTITY_RESULT
readonly archive_mount_identity
require_same_archive_mount 'before preparing the transfer' || exit $?
if [ -L "$archive_temp_root" ] ||
   { [ -e "$archive_temp_root" ] && [ ! -d "$archive_temp_root" ]; }
then
  write_archive_error "$archive_temp_root must be a real directory"
  exit 73
fi
mkdir -p -- "$archive_temp_root"
if [ -L "$archive_temp_root" ] || [ ! -d "$archive_temp_root" ]
then
  write_archive_error "failed to create a safe archive temporary directory"
  exit 73
fi
archive_temp_dir=$(mktemp -d "$archive_temp_root/run.XXXXXX")
if [ -L "$archive_temp_dir" ] || [ ! -d "$archive_temp_dir" ]
then
  write_archive_error "failed to create a private archive temporary directory"
  exit 73
fi
archive_temp_dir_safe=true
archive_temp_relative=".teslausbtmp/${archive_temp_dir##*/}"

pair=0
while [ "$#" -gt 0 ]
do
  if [ "$#" -lt 2 ]
  then
    write_archive_error 'archive-clips received an incomplete source/list pair'
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

  : > "$workdir/rsync-command.log"
  : > "$workdir/rsync-output.log"
  require_same_archive_mount 'before file transfer' || exit $?
  rsync_status=0
  run_monitored_rsync "${rsync_flags[@]}" \
    --temp-dir="$archive_temp_relative" \
    --log-file="$workdir/rsync-command.log" \
    --files-from="$file_list" "$source_root/" "$ARCHIVE_MOUNT" \
    > "$workdir/rsync-output.log" 2>&1 || rsync_status=$?
  require_same_archive_mount 'after file transfer' || exit $?
  if [ "$rsync_status" -ne 0 ] && [ "$rsync_status" -ne 24 ]
  then
    write_archive_error "rsync failed with status $rsync_status"
    exit "$rsync_status"
  fi

  if ! archive_manifest_verify_local "$ARCHIVE_MOUNT" "$manifest"
  then
    write_archive_error 'destination checksum verification failed'
    exit 74
  fi
  require_same_archive_mount 'after destination verification' || exit $?

  manifest_name=$(archive_manifest_name "$manifest" "$pair")
  if ! archive_manifest_publish_local "$ARCHIVE_MOUNT" "$manifest" "$manifest_name"
  then
    write_archive_error 'failed to publish archive integrity manifest'
    exit 73
  fi
  require_same_archive_mount 'after publishing the integrity manifest' || exit $?

  # Source entries are removed only after every destination entry and the
  # published manifest have been verified.
  remove_status=0
  archive_manifest_remove_sources "$source_root" "$manifest" \
    archive_before_local_source_remove || remove_status=$?
  if [ "$remove_status" -ne 0 ]
  then
    write_archive_error 'destination verified, but one or more sources could not be removed'
    if [ "$remove_status" -eq 76 ]
    then
      exit 76
    fi
    exit 75
  fi
done
