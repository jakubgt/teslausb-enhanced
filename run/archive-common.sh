#!/bin/bash

# Shared archive reliability helpers. This file is sourced by archiveloop and
# the archive backends; it intentionally does not change the caller's shell
# options.

ARCHIVE_STATE_DIR="${ARCHIVE_STATE_DIR:-/mutable/teslausb}"
ARCHIVE_STATUS_FILE="${ARCHIVE_STATUS_FILE:-$ARCHIVE_STATE_DIR/archive-status.json}"
ARCHIVE_RETRY_STATE_FILE="${ARCHIVE_RETRY_STATE_FILE:-$ARCHIVE_STATE_DIR/archive-retry.state}"

archive_timestamp() {
  date --utc +'%Y-%m-%dT%H:%M:%SZ'
}

archive_json_escape() {
  local value="$1"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  ARCHIVE_JSON_ESCAPED="\"$value\""
}

archive_is_unsigned_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "${#1}" -le 18 ]
}

archive_prepare_real_directory() {
  local directory="$1"

  if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }
  then
    return 1
  fi
  mkdir -p -- "$directory" || return
  [ -d "$directory" ] && [ ! -L "$directory" ]
}

archive_path_fingerprint() {
  local path="$1"
  local link_fingerprint
  local target_fingerprint

  # Record both the directory entry and its target. Archive candidates are
  # commonly symbolic links into an immutable snapshot, so following links is
  # intentional here while still detecting a link swap or retarget.
  link_fingerprint=$(stat --format='%d:%i:%s:%f:%Y:%Z' -- "$path") || return
  target_fingerprint=$(stat -L --format='%d:%i:%s:%f:%Y:%Z' -- "$path") || return
  printf '%s|%s\n' "$link_fingerprint" "$target_fingerprint"
}

archive_manifest_measure_file() {
  local path="$1"
  local before
  local after
  local digest
  local size

  [ -f "$path" ] || return 1
  before=$(archive_path_fingerprint "$path") || return
  size=$(stat -L --format='%s' -- "$path") || return
  digest=$(sha256sum -- "$path") || return
  digest=${digest%% *}
  after=$(archive_path_fingerprint "$path") || return
  [ "$before" = "$after" ] || return 1

  ARCHIVE_ENTRY_SIZE=$size
  ARCHIVE_ENTRY_DIGEST=$digest
  ARCHIVE_ENTRY_FINGERPRINT=$after
}

archive_manifest_entry_matches() {
  local path="$1"
  local expected_digest="$2"
  local expected_size="$3"

  archive_manifest_measure_file "$path" || return
  [ "$ARCHIVE_ENTRY_SIZE" = "$expected_size" ] || return 1
  [ "$ARCHIVE_ENTRY_DIGEST" = "$expected_digest" ] || return 1
}

archive_status_write() {
  local last_result="$1"
  local last_started="$2"
  local last_finished="$3"
  local pending_files="$4"
  local pending_bytes="$5"
  local transferred_files="$6"
  local transferred_bytes="$7"
  local message="$8"
  local status_dir
  local tmp
  local result_json
  local started_json
  local finished_json
  local message_json

  archive_is_unsigned_integer "$pending_files" || return 2
  archive_is_unsigned_integer "$pending_bytes" || return 2
  archive_is_unsigned_integer "$transferred_files" || return 2
  archive_is_unsigned_integer "$transferred_bytes" || return 2

  status_dir=$(dirname -- "$ARCHIVE_STATUS_FILE") || return
  archive_prepare_real_directory "$status_dir" || return
  tmp=$(mktemp "$status_dir/.archive-status.XXXXXX") || return

  archive_json_escape "$last_result"
  result_json=$ARCHIVE_JSON_ESCAPED
  archive_json_escape "$last_started"
  started_json=$ARCHIVE_JSON_ESCAPED
  archive_json_escape "$last_finished"
  finished_json=$ARCHIVE_JSON_ESCAPED
  archive_json_escape "$message"
  message_json=$ARCHIVE_JSON_ESCAPED

  if ! printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    "  \"last_result\": $result_json," \
    "  \"last_started\": $started_json," \
    "  \"last_finished\": $finished_json," \
    "  \"pending_files\": $pending_files," \
    "  \"pending_bytes\": $pending_bytes," \
    "  \"transferred_files\": $transferred_files," \
    "  \"transferred_bytes\": $transferred_bytes," \
    "  \"message\": $message_json" \
    '}' > "$tmp"
  then
    rm -f -- "$tmp"
    return 1
  fi

  chmod 0644 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! mv -f -- "$tmp" "$ARCHIVE_STATUS_FILE"
  then
    rm -f -- "$tmp"
    return 1
  fi
}

archive_valid_relative_path() {
  local path="$1"

  [ -n "$path" ] || return 1
  case "$path" in
    /* | . | .. | ../* | */../* | */.. | ./* | */./* | */. | *$'\n'* | *$'\r'* | *$'\t'*)
      return 1
      ;;
  esac
}

archive_manifest_create() {
  local source_root="$1"
  local file_list="$2"
  local manifest="$3"
  local relative
  local source_path
  local manifest_dir
  local tmp

  manifest_dir=$(dirname -- "$manifest") || return
  archive_prepare_real_directory "$manifest_dir" || return
  tmp=$(mktemp "$manifest_dir/.archive-manifest.XXXXXX") || return
  while IFS= read -r relative || [ -n "$relative" ]
  do
    [ -n "$relative" ] || continue
    if ! archive_valid_relative_path "$relative"
    then
      printf 'Unsafe archive path: %s\n' "$relative" >&2
      rm -f -- "$tmp"
      return 1
    fi
    source_path="$source_root/$relative"
    # Snapshot entries can disappear while a previous successful retry is
    # being resumed. Missing entries are already complete.
    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]
    then
      continue
    fi
    if ! archive_manifest_measure_file "$source_path"
    then
      printf 'Archive source changed while it was being hashed: %s\n' "$relative" >&2
      rm -f -- "$tmp"
      return 1
    fi
    printf '%s\t%s\t%s\n' \
      "$ARCHIVE_ENTRY_DIGEST" "$ARCHIVE_ENTRY_SIZE" "$relative" >> "$tmp" || {
      rm -f -- "$tmp"
      return 1
    }
  done < "$file_list"
  mv -f -- "$tmp" "$manifest"
}

archive_manifest_stats() {
  local manifest="$1"

  awk -F '\t' '{ files += 1; bytes += $2 } END { printf "%d %d\n", files, bytes }' "$manifest"
}

archive_manifest_name() {
  local manifest="$1"
  local pair="${2:-1}"
  local digest

  archive_is_unsigned_integer "$pair" || return 2
  digest=$(sha256sum -- "$manifest") || return
  digest=${digest%% *}
  printf 'archive-%s-%s-%s.tsv\n' \
    "$(date --utc +%Y%m%dT%H%M%SZ)" "$digest" "$pair"
}

archive_manifest_removed_stats() {
  local source_root="$1"
  local manifest="$2"
  local size
  local relative
  local files=0
  local bytes=0

  while IFS=$'\t' read -r _ size relative
  do
    [ -n "$relative" ] || continue
    if [ ! -e "$source_root/$relative" ] && [ ! -L "$source_root/$relative" ]
    then
      files=$((files + 1))
      bytes=$((bytes + size))
    fi
  done < "$manifest"
  printf '%d %d\n' "$files" "$bytes"
}

archive_manifest_verify_local() {
  local destination_root="$1"
  local manifest="$2"
  local expected_digest
  local expected_size
  local relative
  local destination_path

  while IFS=$'\t' read -r expected_digest expected_size relative
  do
    [ -n "$relative" ] || continue
    archive_valid_relative_path "$relative" || return 1
    destination_path="$destination_root/$relative"
    # An archive entry must own its bytes. Following a destination symlink
    # could otherwise verify unrelated storage and then delete the source.
    [ ! -L "$destination_path" ] || return 1
    archive_manifest_entry_matches \
      "$destination_path" "$expected_digest" "$expected_size" || return
    [ ! -L "$destination_path" ] || return 1
  done < "$manifest"
}

archive_manifest_verify_sources() {
  local source_root="$1"
  local manifest="$2"
  local expected_digest
  local expected_size
  local relative

  while IFS=$'\t' read -r expected_digest expected_size relative
  do
    [ -n "$relative" ] || continue
    archive_valid_relative_path "$relative" || return 1
    archive_manifest_entry_matches \
      "$source_root/$relative" "$expected_digest" "$expected_size" || return
  done < "$manifest"
}

archive_manifest_publish_local() {
  local destination_root="$1"
  local manifest="$2"
  local manifest_name="$3"
  local destination_dir="$destination_root/.teslausb-manifests"
  local tmp

  case "$manifest_name" in
    '' | . | .. | */*)
      return 2
      ;;
  esac
  archive_prepare_real_directory "$destination_dir" || return
  tmp=$(mktemp "$destination_dir/.manifest.XXXXXX") || return
  if ! cp -- "$manifest" "$tmp"
  then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0644 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$destination_dir/$manifest_name"
}

archive_manifest_remove_sources() {
  local source_root="$1"
  local manifest="$2"
  local before_remove="${3:-}"
  local digest
  local size
  local relative
  local source_path
  local verified_fingerprint
  local final_fingerprint

  if [ -n "$before_remove" ] &&
     { [[ ! "$before_remove" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
       ! declare -F "$before_remove" > /dev/null; }
  then
    return 2
  fi

  while IFS=$'\t' read -r digest size relative
  do
    [ -n "$relative" ] || continue
    archive_valid_relative_path "$relative" || return 1
    source_path="$source_root/$relative"
    if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]
    then
      continue
    fi
    archive_manifest_entry_matches "$source_path" "$digest" "$size" || return
    verified_fingerprint=$ARCHIVE_ENTRY_FINGERPRINT
    # Local network-mount backends pass a guard which rechecks that the
    # destination is still the exact mount that was originally connected.
    # Remote backends omit the callback.
    if [ -n "$before_remove" ]
    then
      "$before_remove" "$source_path" || return
    fi
    # Revalidate the directory entry and target once more immediately before
    # unlinking. This preserves a new recording if the snapshot link was
    # replaced after destination verification or during the cleanup pass.
    final_fingerprint=$(archive_path_fingerprint "$source_path") || return
    [ "$final_fingerprint" = "$verified_fingerprint" ] || return 1
    rm -f -- "$source_path" || return
  done < "$manifest"
}

archive_retry_load() {
  ARCHIVE_RETRY_FAILURES=0
  ARCHIVE_RETRY_NOT_BEFORE=0
  if [ -f "$ARCHIVE_RETRY_STATE_FILE" ] &&
     [ ! -L "$ARCHIVE_RETRY_STATE_FILE" ] &&
     [ -r "$ARCHIVE_RETRY_STATE_FILE" ]
  then
    read -r ARCHIVE_RETRY_FAILURES ARCHIVE_RETRY_NOT_BEFORE < "$ARCHIVE_RETRY_STATE_FILE" || true
  fi
  archive_is_unsigned_integer "$ARCHIVE_RETRY_FAILURES" || ARCHIVE_RETRY_FAILURES=0
  archive_is_unsigned_integer "$ARCHIVE_RETRY_NOT_BEFORE" || ARCHIVE_RETRY_NOT_BEFORE=0
  [ "$ARCHIVE_RETRY_FAILURES" -le 30 ] || ARCHIVE_RETRY_FAILURES=30
}

archive_retry_save() {
  local failures="$1"
  local not_before="$2"
  local state_dir
  local tmp

  archive_is_unsigned_integer "$failures" || return 2
  archive_is_unsigned_integer "$not_before" || return 2
  [ "$failures" -le 30 ] || return 2
  state_dir=$(dirname -- "$ARCHIVE_RETRY_STATE_FILE") || return
  archive_prepare_real_directory "$state_dir" || return
  tmp=$(mktemp "$state_dir/.archive-retry.XXXXXX") || return
  if ! printf '%s %s\n' "$failures" "$not_before" > "$tmp"
  then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! mv -f -- "$tmp" "$ARCHIVE_RETRY_STATE_FILE"
  then
    rm -f -- "$tmp"
    return 1
  fi
}

archive_retry_reset() {
  rm -f -- "$ARCHIVE_RETRY_STATE_FILE"
}

archive_retry_run() {
  local attempts_this_run=0
  local max_attempts="${ARCHIVE_RETRY_ATTEMPTS_PER_RUN:-3}"
  local base_delay="${ARCHIVE_RETRY_BASE_SECONDS:-5}"
  local max_delay="${ARCHIVE_RETRY_MAX_SECONDS:-60}"
  local now
  local wait_seconds
  local status=1
  local delay
  local exponent

  archive_is_unsigned_integer "$max_attempts" || return 2
  archive_is_unsigned_integer "$base_delay" || return 2
  archive_is_unsigned_integer "$max_delay" || return 2
  [ "$max_attempts" -gt 0 ] || return 2
  [ "$max_attempts" -le 10 ] || return 2
  [ "$base_delay" -le 86400 ] || return 2
  [ "$max_delay" -le 86400 ] || return 2

  while [ "$attempts_this_run" -lt "$max_attempts" ]
  do
    archive_retry_load
    now=$(date +%s)
    if [ "$ARCHIVE_RETRY_NOT_BEFORE" -gt "$now" ]
    then
      wait_seconds=$((ARCHIVE_RETRY_NOT_BEFORE - now))
      # Treat persisted state as untrusted input. A damaged clock or state
      # file must not make the archive service sleep for an arbitrary period.
      [ "$wait_seconds" -le "$max_delay" ] || wait_seconds=$max_delay
      "${ARCHIVE_SLEEP_BIN:-sleep}" "$wait_seconds" || return
    fi

    if "$@"
    then
      archive_retry_reset
      return 0
    else
      status=$?
    fi

    if [ "$ARCHIVE_RETRY_FAILURES" -lt 30 ]
    then
      ARCHIVE_RETRY_FAILURES=$((ARCHIVE_RETRY_FAILURES + 1))
    fi
    exponent=$((ARCHIVE_RETRY_FAILURES - 1))
    [ "$exponent" -le 10 ] || exponent=10
    delay=$((base_delay * (1 << exponent)))
    [ "$delay" -le "$max_delay" ] || delay=$max_delay
    now=$(date +%s)
    archive_retry_save "$ARCHIVE_RETRY_FAILURES" "$((now + delay))" || return
    attempts_this_run=$((attempts_this_run + 1))
  done
  return "$status"
}
