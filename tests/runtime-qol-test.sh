#!/bin/bash -eu

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname -- "$TEST_DIR")
readonly REPO_ROOT
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
tracked_test_pids=()
cleanup() {
  local pid
  for pid in "${tracked_test_pids[@]}"
  do
    [ -n "$pid" ] || continue
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  done
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

fakebin="$TEST_TMP/bin"
mkdir -p "$fakebin"
curl_args="$TEST_TMP/curl-args"
# shellcheck disable=SC2016 # This block writes a separate test script.
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$@" > "$CURL_ARGS"' \
  'exit 0' > "$fakebin/curl"
chmod +x "$fakebin/curl"

function log { :; }
export -f log
export CURL_ARGS="$curl_args"
PUSHOVER_ENABLED=true \
PUSHOVER_APP_KEY=app \
PUSHOVER_USER_KEY=user \
PATH="$fakebin:$PATH" \
  bash "$REPO_ROOT/run/send-push-message" title message

grep -Fx -- '--connect-timeout' "$curl_args" > /dev/null \
  || fail 'notification curl lacks a connect timeout'
grep -Fx -- '--max-time' "$curl_args" > /dev/null \
  || fail 'notification curl lacks a total timeout'
grep -Fx -- '--fail' "$curl_args" > /dev/null \
  || fail 'notification curl does not fail on HTTP errors'

python_args="$TEST_TMP/python-args"
python_stdin="$TEST_TMP/python-stdin"
python_env="$TEST_TMP/python-env"
fake_python="$fakebin/python"
# shellcheck disable=SC2016 # This block writes a separate test script.
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$@" > "$PYTHON_ARGS"' \
  'cat > "$PYTHON_STDIN"' \
  'env > "$PYTHON_ENV"' > "$fake_python"
chmod +x "$fake_python"
export PYTHON_ARGS="$python_args"
export PYTHON_STDIN="$python_stdin"
export PYTHON_ENV="$python_env"
MATRIX_ENABLED=true \
MATRIX_SERVER_URL=https://matrix.example.invalid \
MATRIX_USERNAME=teslausb \
MATRIX_PASSWORD='not-in-process-arguments' \
MATRIX_ROOM='!room:example.invalid' \
TESLAUSB_PYTHON="$fake_python" \
  bash "$REPO_ROOT/run/send-push-message" title message
[ "$(<"$python_stdin")" = 'not-in-process-arguments' ] \
  || fail 'Matrix password was not delivered on standard input'
if grep -F 'not-in-process-arguments' "$python_args" > /dev/null
then
  fail 'Matrix password was exposed in process arguments'
fi
if grep -q '^MATRIX_PASSWORD=' "$python_env"
then
  fail 'Matrix password was inherited in the helper environment'
fi
grep -F -- 'timeout --foreground --kill-after=5s' \
  "$REPO_ROOT/run/send-push-message" > /dev/null \
  || fail 'Python notification helpers lack a total timeout'
if grep -En 'teslausb_curl[[:space:]]+-v([[:space:]]|$)' \
    "$REPO_ROOT/run/send-push-message" > /dev/null
then
  fail 'notification curl still enables verbose credential-adjacent output'
fi

sync_marker="$TEST_TMP/archive-is-unreachable"
status=0
FORCE_SYNC_MARKER="$sync_marker" FORCE_SYNC_TIMEOUT_SECONDS=0 \
  bash "$REPO_ROOT/run/force_sync.sh" > /dev/null 2>&1 || status=$?
[ "$status" -eq 124 ] || fail "force sync timeout returned $status instead of 124"
[ -e "$sync_marker" ] || fail 'timed-out sync request was not left queued'

if grep -REn 'killall[[:space:]]+(rsync|archiveloop)' "$REPO_ROOT/run" > "$TEST_TMP/killall.txt"
then
  cat "$TEST_TMP/killall.txt" >&2
  fail 'runtime scripts still use process-global killall'
fi
# shellcheck disable=SC2016 # The assertion intentionally searches literal shell source.
grep -F -- '--timeout="${MUSIC_RSYNC_TIMEOUT:-60}"' "$REPO_ROOT/run/copy-music.sh" > /dev/null \
  || fail 'music rsync lacks an I/O timeout'
# shellcheck disable=SC2016 # The assertion intentionally searches literal shell source.
grep -F -- '--timeout="${ARCHIVE_RSYNC_TIMEOUT:-60}"' \
  "$REPO_ROOT/run/archive-rsync-local.sh" > /dev/null \
  || fail 'local archive rsync lacks an I/O timeout'
grep -F 'TESLA_BLE_COMMAND_TIMEOUT_SECONDS' "$REPO_ROOT/run/awake_start" > /dev/null \
  || fail 'awake BLE command lacks a total timeout'
grep -F 'TESLA_BLE_COMMAND_TIMEOUT_SECONDS' "$REPO_ROOT/run/awake_stop" > /dev/null \
  || fail 'sleep BLE command lacks a total timeout'

export KEEP_AWAKE_PID_FILE="$TEST_TMP/keep-awake.pid"
export KEEP_AWAKE_PROC_ROOT=/proc
# shellcheck source=run/keep-awake-pid.sh
source "$REPO_ROOT/run/keep-awake-pid.sh"

sleep 30 &
tracked_pid=$!
tracked_test_pids+=("$tracked_pid")
keep_awake_pid_write "$tracked_pid" || fail 'could not persist a tracked process identity'
keep_awake_pid_read || fail 'could not read a tracked process identity'
[ "$KEEP_AWAKE_PID" -eq "$tracked_pid" ] || fail 'PID file returned a different process'
keep_awake_pid_stop
wait "$tracked_pid" 2> /dev/null || true
tracked_test_pids[0]=
if kill -0 "$tracked_pid" 2> /dev/null
then
  fail 'exact-process stop left the tracked process running'
fi

sleep 30 &
reused_pid=$!
tracked_test_pids+=("$reused_pid")
reused_start=$(keep_awake_pid_starttime "$reused_pid")
printf '%s %s\n' "$reused_pid" "$((reused_start + 1))" > "$KEEP_AWAKE_PID_FILE"
keep_awake_pid_stop
kill -0 "$reused_pid" 2> /dev/null \
  || fail 'stale PID metadata killed an unrelated process'
kill "$reused_pid" 2> /dev/null || true
wait "$reused_pid" 2> /dev/null || true
tracked_test_pids[1]=

# shellcheck disable=SC2016 # The assertion intentionally searches literal shell source.
grep -F 'source "$keep_awake_pid_helper"' "$REPO_ROOT/run/awake_start" > /dev/null \
  || fail 'awake_start does not use exact-process PID tracking'
# shellcheck disable=SC2016 # The assertion intentionally searches literal shell source.
grep -F 'source "$keep_awake_pid_helper"' "$REPO_ROOT/run/awake_stop" > /dev/null \
  || fail 'awake_stop does not use exact-process PID tracking'
if grep -RFn '/tmp/keep_awake_task_pid' "$REPO_ROOT/run/awake_start" "$REPO_ROOT/run/awake_stop"
then
  fail 'legacy predictable keep-awake PID file remains'
fi

printf 'runtime QOL tests passed\n'
