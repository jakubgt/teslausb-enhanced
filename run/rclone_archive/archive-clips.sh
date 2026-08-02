#!/bin/bash -eu

set -o pipefail

# Read setup variables again because arrays, such as RCLONE_FLAGS, do not
# export to child scripts.
source /root/bin/envsetup.sh
archive_common="${ARCHIVE_COMMON_SH:-/root/bin/archive-common.sh}"
# shellcheck source=run/archive-common.sh
source "$archive_common"

flags=(
  -L
  --transfers=1
  --contimeout="${RCLONE_CONNECT_TIMEOUT:-15s}"
  --timeout="${RCLONE_IO_TIMEOUT:-5m}"
)
if [[ -v RCLONE_FLAGS ]]
then
  flags+=("${RCLONE_FLAGS[@]}")
fi

workdir=$(mktemp -d "${ARCHIVE_WORK_ROOT:-/tmp}/teslausb-rclone-archive.XXXXXX")
readonly workdir
trap 'rm -rf -- "$workdir"' EXIT
trap 'exit 1' HUP INT TERM

remote_root="$RCLONE_DRIVE:$RCLONE_PATH"
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

  if ! "${ARCHIVE_RCLONE_BIN:-rclone}" --config /root/.config/rclone/rclone.conf \
      copy "${flags[@]}" --files-from "$file_list" "$source_root" "$remote_root" \
      >> "$LOG_FILE" 2>&1
  then
    printf 'rclone copy failed\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 1
  fi

  if ! archive_manifest_verify_sources "$source_root" "$manifest"
  then
    printf 'Source changed while rclone was transferring; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  if ! "${ARCHIVE_RCLONE_BIN:-rclone}" --config /root/.config/rclone/rclone.conf \
      check "${flags[@]}" --one-way --files-from "$file_list" "$source_root" "$remote_root" \
      >> "$LOG_FILE" 2>&1
  then
    printf 'rclone destination checksum verification failed\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  if ! archive_manifest_verify_sources "$source_root" "$manifest"
  then
    printf 'Source changed during rclone verification; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 74
  fi

  manifest_name=$(archive_manifest_name "$manifest" "$pair")
  if ! "${ARCHIVE_RCLONE_BIN:-rclone}" --config /root/.config/rclone/rclone.conf \
      copyto "$manifest" "$remote_root/.teslausb-manifests/$manifest_name" \
      >> "$LOG_FILE" 2>&1
  then
    printf 'Failed to publish rclone archive integrity manifest\n' > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 73
  fi

  if ! archive_manifest_remove_sources "$source_root" "$manifest"
  then
    printf 'Destination verified, but a source changed before removal; retaining it for retry\n' \
      > "${ARCHIVE_ERROR_LOG:-/tmp/archive-error.log}"
    exit 75
  fi
done
