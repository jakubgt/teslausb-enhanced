#!/bin/bash

# Detect non-empty Tesla EncryptedClips directories and publish a small status
# document. This script reads directory entries only; it does not inspect clip
# contents, handle keys, decrypt, copy, move, or delete any recording.

set -eu

status_file=
archive_list=
archive_root=
declare -a search_roots=()
while [ "$#" -gt 0 ]
do
  case "$1" in
    --status-file)
      [ "$#" -ge 2 ] || {
        echo "--status-file requires a path" >&2
        exit 2
      }
      status_file="$2"
      shift 2
      ;;
    --prune-archive-list)
      [ "$#" -ge 2 ] || {
        echo "--prune-archive-list requires a path" >&2
        exit 2
      }
      archive_list="$2"
      shift 2
      ;;
    --archive-root)
      [ "$#" -ge 2 ] || {
        echo "--archive-root requires a path" >&2
        exit 2
      }
      archive_root="$2"
      shift 2
      ;;
    --)
      shift
      search_roots+=("$@")
      break
      ;;
    -* )
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      search_roots+=("$1")
      shift
      ;;
  esac
done

if [ -n "$archive_list" ]
then
  if [ -n "$status_file" ] || [ "${#search_roots[@]}" -ne 0 ]
  then
    echo "--prune-archive-list cannot be combined with detection options or roots" >&2
    exit 2
  fi
  if [ -z "$archive_root" ]
  then
    echo "--prune-archive-list requires --archive-root" >&2
    exit 2
  fi
  if [ -L "$archive_list" ] || [ ! -f "$archive_list" ]
  then
    echo "archive candidate list must be a regular non-symlink file" >&2
    exit 1
  fi
  archive_list_dir=$(dirname -- "$archive_list")
  if [ -L "$archive_list_dir" ] || [ ! -d "$archive_list_dir" ]
  then
    echo "archive candidate list directory must be a real directory" >&2
    exit 1
  fi
  if [ -L "$archive_root" ] || [ ! -d "$archive_root" ]
  then
    echo "archive root must be a real directory" >&2
    exit 1
  fi
  canonical_archive_root=$(realpath -e -- "$archive_root") || {
    echo "archive root could not be resolved" >&2
    exit 1
  }
  archive_list_tmp=$(mktemp "$archive_list_dir/.encrypted-clips-prune.XXXXXX")
  trap 'rm -f -- "$archive_list_tmp"' EXIT
  while IFS= read -r archive_candidate || [ -n "$archive_candidate" ]
  do
    keep_candidate=true
    case "$archive_candidate" in
      EncryptedClips | EncryptedClips/* | */EncryptedClips | */EncryptedClips/*)
        keep_candidate=false
        ;;
    esac
    case "$archive_candidate" in
      '' | /* | ../* | */../* | */.. | . | .. | *$'\r'* | *$'\t'*)
        keep_candidate=false
        ;;
    esac
    if [ "$keep_candidate" = true ]
    then
      candidate_path=$(realpath -e -- "$canonical_archive_root/$archive_candidate") ||
        keep_candidate=false
      case "${candidate_path:-}" in
        */EncryptedClips | */EncryptedClips/*)
          keep_candidate=false
          ;;
      esac
    fi
    if [ "$keep_candidate" = true ]
    then
      printf '%s\n' "$archive_candidate" >> "$archive_list_tmp"
    fi
  done < "$archive_list"
  chmod --reference="$archive_list" "$archive_list_tmp"
  chown --reference="$archive_list" "$archive_list_tmp"
  mv -fT -- "$archive_list_tmp" "$archive_list"
  trap - EXIT
  exit 0
fi

if [ -n "$archive_root" ]
then
  echo "--archive-root requires --prune-archive-list" >&2
  exit 2
fi

# A failed or indeterminate inspection must not leave a previously-published
# clear result visible to the dashboard. Removing the status document makes the
# status API report the conservative built-in unavailable state.
invalidate_status_file() {
  local invalidation_dir

  [ -n "$status_file" ] || return 0
  invalidation_dir=$(dirname -- "$status_file")
  if [ -L "$invalidation_dir" ] || [ ! -d "$invalidation_dir" ]
  then
    return 0
  fi
  if [ -e "$status_file" ] || [ -L "$status_file" ]
  then
    rm -f -- "$status_file"
  fi
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
path_status_helper="${TESLAUSB_ENCRYPTED_PATH_STATUS_HELPER:-$script_dir/encrypted_clips_path_status.sh}"
if [ ! -x "$path_status_helper" ]
then
  if ! invalidate_status_file
  then
    echo "could not invalidate stale encrypted-clip status" >&2
  fi
  echo "encrypted-clip path-status helper is unavailable" >&2
  exit 1
fi

if [ "${#search_roots[@]}" -eq 0 ]
then
  search_roots=(/mnt/cam/TeslaCam /mutable/TeslaCam)
fi

detected=false
locations=0
for root in "${search_roots[@]}"
do
  candidate="$root/EncryptedClips"
  candidate_status=0
  "$path_status_helper" "$candidate" || candidate_status=$?
  case "$candidate_status" in
    0)
      detected=true
      locations=$((locations + 1))
      ;;
    1)
      ;;
    *)
      if ! invalidate_status_file
      then
        echo "could not invalidate stale encrypted-clip status" >&2
      fi
      echo "could not safely inspect $candidate" >&2
      exit 1
      ;;
  esac
done

checked_at=$(date --utc '+%Y-%m-%dT%H:%M:%SZ')
if [ "$detected" = true ]
then
  message='Encrypted Dashcam clips detected. TeslaUSB leaves them untouched and cannot archive or play them.'
else
  message='No non-empty EncryptedClips directory was detected in the mounted camera or snapshot view.'
fi
json=$(printf '{"schema_version":1,"detected":%s,"locations":%d,"checked_at":"%s","message":"%s"}' \
  "$detected" "$locations" "$checked_at" "$message")

if [ -n "$status_file" ]
then
  status_dir=$(dirname -- "$status_file")
  if [ -L "$status_dir" ]
  then
    echo "status directory must not be a symbolic link" >&2
    exit 1
  fi
  install -d -o root -g root -m 0755 -- "$status_dir"
  status_tmp=$(mktemp "$status_dir/.encrypted-clips-status.XXXXXX")
  trap 'rm -f -- "$status_tmp"' EXIT
  printf '%s\n' "$json" > "$status_tmp"
  chown root:root "$status_tmp"
  chmod 0644 "$status_tmp"
  mv -fT -- "$status_tmp" "$status_file"
  trap - EXIT
fi

printf '%s\n' "$json"
