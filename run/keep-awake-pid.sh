#!/bin/bash

# Exact-process PID file helpers shared by awake_start and awake_stop. The
# Linux process start time prevents a stale PID file from signalling an
# unrelated process after PID reuse.

KEEP_AWAKE_PID_FILE="${KEEP_AWAKE_PID_FILE:-/run/teslausb/keep-awake.pid}"
KEEP_AWAKE_PROC_ROOT="${KEEP_AWAKE_PROC_ROOT:-/proc}"

keep_awake_pid_starttime() {
  local pid="$1"
  local stat_file="$KEEP_AWAKE_PROC_ROOT/$pid/stat"
  local stat_line
  local after_name

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  IFS= read -r stat_line < "$stat_file" || return
  # Strip fields 1 and 2. Field 2 is parenthesized and may contain spaces;
  # field 22 (starttime) is then token 20 in the remainder.
  after_name=${stat_line##*) }
  # shellcheck disable=SC2086 # /proc fields are intentionally word-split.
  set -- $after_name
  [ "$#" -ge 20 ] || return 1
  [[ "${20}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${20}"
}

keep_awake_pid_state() {
  local pid="$1"
  local stat_line
  local after_name

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  IFS= read -r stat_line < "$KEEP_AWAKE_PROC_ROOT/$pid/stat" || return
  after_name=${stat_line##*) }
  printf '%s\n' "${after_name%% *}"
}

keep_awake_pid_read() {
  local extra=
  local actual_starttime

  KEEP_AWAKE_PID=
  KEEP_AWAKE_STARTTIME=
  [ -f "$KEEP_AWAKE_PID_FILE" ] && [ ! -L "$KEEP_AWAKE_PID_FILE" ] || return 1
  read -r KEEP_AWAKE_PID KEEP_AWAKE_STARTTIME extra < "$KEEP_AWAKE_PID_FILE" || return
  [ -z "$extra" ] || return 1
  [[ "$KEEP_AWAKE_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$KEEP_AWAKE_STARTTIME" =~ ^[0-9]+$ ]] || return 1
  actual_starttime=$(keep_awake_pid_starttime "$KEEP_AWAKE_PID") || return
  [ "$actual_starttime" = "$KEEP_AWAKE_STARTTIME" ] || return 1
  kill -0 "$KEEP_AWAKE_PID" 2> /dev/null
}

keep_awake_pid_write() {
  local pid="$1"
  local starttime
  local state_dir
  local tmp

  starttime=$(keep_awake_pid_starttime "$pid") || return
  state_dir=$(dirname -- "$KEEP_AWAKE_PID_FILE") || return
  if [ -L "$state_dir" ] || { [ -e "$state_dir" ] && [ ! -d "$state_dir" ]; }
  then
    return 1
  fi
  mkdir -p -- "$state_dir" || return
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  chmod 0755 "$state_dir" || return
  tmp=$(mktemp "$state_dir/.keep-awake.XXXXXX") || return
  if ! printf '%s %s\n' "$pid" "$starttime" > "$tmp"
  then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! mv -f -- "$tmp" "$KEEP_AWAKE_PID_FILE"
  then
    rm -f -- "$tmp"
    return 1
  fi
}

keep_awake_pid_stop() {
  local _
  local actual_starttime

  if ! keep_awake_pid_read
  then
    if [ -e "$KEEP_AWAKE_PID_FILE" ] || [ -L "$KEEP_AWAKE_PID_FILE" ]
    then
      rm -f -- "$KEEP_AWAKE_PID_FILE"
    fi
    return 0
  fi

  kill "$KEEP_AWAKE_PID" 2> /dev/null || true
  for _ in {1..50}
  do
    actual_starttime=$(keep_awake_pid_starttime "$KEEP_AWAKE_PID" 2> /dev/null) || break
    [ "$actual_starttime" = "$KEEP_AWAKE_STARTTIME" ] || break
    [ "$(keep_awake_pid_state "$KEEP_AWAKE_PID" 2> /dev/null || true)" != Z ] || break
    sleep 0.1
  done
  actual_starttime=$(keep_awake_pid_starttime "$KEEP_AWAKE_PID" 2> /dev/null) || actual_starttime=
  if [ "$actual_starttime" = "$KEEP_AWAKE_STARTTIME" ] &&
     [ "$(keep_awake_pid_state "$KEEP_AWAKE_PID" 2> /dev/null || true)" != Z ]
  then
    kill -KILL "$KEEP_AWAKE_PID" 2> /dev/null || true
  fi
  rm -f -- "$KEEP_AWAKE_PID_FILE"
}
