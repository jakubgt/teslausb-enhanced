#!/bin/bash -eu

set -eu

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "$TEST_DIR")
TEST_TMP=$(mktemp -d)
readonly TEST_DIR REPO_ROOT TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir "$TEST_TMP/bin"
export PROBE_ARGUMENTS="$TEST_TMP/probe-arguments"
export TIMEOUT_ARGUMENTS="$TEST_TMP/timeout-arguments"
export PROBE_STATUS=0
cat > "$TEST_TMP/bin/rclone" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" > "$PROBE_ARGUMENTS"
printf 'private-provider-url test-secret\n' >&2
printf 'remote object names\n'
exit "$PROBE_STATUS"
EOF
cat > "$TEST_TMP/bin/timeout" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" "$2" "$3" > "$TIMEOUT_ARGUMENTS"
shift 3
exec "$@"
EOF
cat > "$TEST_TMP/bin/ping" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$TEST_TMP/bin/"*
export PATH="$TEST_TMP/bin:$PATH"

export ARCHIVE_RCLONE_BIN="$TEST_TMP/bin/rclone"
export ARCHIVE_TIMEOUT_BIN="$TEST_TMP/bin/timeout"
probe="$REPO_ROOT/run/rclone_archive/archive-is-reachable.sh"
# shellcheck disable=SC2016 # Deliberately literal shell text tests safe arguments.
remote='configured remote:directory with spaces/$(touch never-run)'
captured=$(bash "$probe" "$remote" --header 'X-Token: test-secret' 2>&1)
[ -z "$captured" ] || fail 'provider stdout/stderr escaped the probe'
[ ! -e never-run ] || fail 'remote text was executed'
mapfile -d '' -t args < "$PROBE_ARGUMENTS"
[ "${args[0]}" = --config ] || fail 'probe lost the fixed configuration path'
[ "${args[1]}" = /root/.config/rclone/rclone.conf ] || fail 'unexpected configuration path'
[ "${args[2]}" = lsf ] || fail 'probe is not a read-only backend listing'
if [ "${args[3]}" != --header ] || [ "${args[4]}" != 'X-Token: test-secret' ]
then
  fail 'trusted backend flags were split or changed'
fi
[ "${args[${#args[@]}-2]}" = -- ] || fail 'remote is not separated from options'
[ "${args[${#args[@]}-1]}" = "$remote" ] || fail 'configured destination was split or replaced'
for required in --dirs-only --recursive=false --max-depth=1 --fast-list=false \
  --retries=1 --low-level-retries=1 --contimeout=5s --timeout=10s --ask-password=false
do
  printf '%s\n' "${args[@]}" | grep -Fx -- "$required" > /dev/null \
    || fail "probe lacks $required"
done
[ "$(cat "$TIMEOUT_ARGUMENTS")" = $'--signal=TERM\n--kill-after=2s\n15s' ] \
  || fail 'probe lacks a bounded outer process deadline'

# Missing directories, denied credentials and temporary backend failures must
# remain failures. A successfully listed empty remote is valid (the first call).
for status in 3 5 7 124 137
do
  export PROBE_STATUS="$status"
  actual=0
  captured=$(bash "$probe" "$remote" 2>&1) || actual=$?
  [ "$actual" -eq "$status" ] || fail "backend failure $status was hidden"
  [ -z "$captured" ] || fail 'backend failure exposed provider details'
done
export PROBE_STATUS=0
for invalid in '' missing-colon $'remote:bad\npath' $'remote:bad\rpath'
do
  actual=0
  bash "$probe" "$invalid" || actual=$?
  [ "$actual" -eq 64 ] || fail 'invalid remote was accepted'
done

# Verify that the process deadline really terminates an unresponsive backend.
# The shim shortens the same TERM/kill deadline to keep this fixture fast.
if [ -x /usr/bin/timeout ]
then
cat > "$TEST_TMP/bin/short-timeout" <<'EOF'
#!/bin/sh
[ "$1" = --signal=TERM ] && [ "$2" = --kill-after=2s ] && [ "$3" = 15s ] || exit 90
shift 3
exec /usr/bin/timeout --signal=TERM --kill-after=0.2s 0.2s "$@"
EOF
cat > "$TEST_TMP/bin/hung-rclone" <<'EOF'
#!/bin/sh
printf '%s\n' "$$" > "$PROBE_PID"
exec /bin/sleep 10
EOF
chmod +x "$TEST_TMP/bin/short-timeout" "$TEST_TMP/bin/hung-rclone"
export PROBE_PID="$TEST_TMP/probe-pid"
actual=0
ARCHIVE_TIMEOUT_BIN="$TEST_TMP/bin/short-timeout" \
ARCHIVE_RCLONE_BIN="$TEST_TMP/bin/hung-rclone" \
  bash "$probe" "$remote" || actual=$?
[ "$actual" -eq 124 ] || fail 'outer deadline did not stop an unresponsive backend'
if kill -0 "$(cat "$PROBE_PID")" 2> /dev/null
then
  fail 'timed-out backend was left running'
fi
else
  printf 'Skipping real deadline fixture: GNU timeout is unavailable on this host\n'
fi

# Exercise the production dispatch with a path-only test substitution. Arrays
# and a remote containing spaces must reach the backend as separate literal
# arguments; existing non-rclone backends still receive ARCHIVE_SERVER alone.
cat > "$TEST_TMP/bin/record-arguments" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" > "$PROBE_ARGUMENTS"
EOF
chmod +x "$TEST_TMP/bin/record-arguments"
dispatch=$(sed -n '/^function archive_is_reachable () {$/,/^}$/p' "$REPO_ROOT/run/archiveloop")
dispatch=${dispatch//\/root\/bin\/archive-is-reachable.sh/\"$TEST_TMP\/bin\/record-arguments\"}
eval "$dispatch"
ARCHIVE_SYSTEM=rclone
RCLONE_DRIVE='configured remote'
RCLONE_PATH='a folder with spaces'
RCLONE_FLAGS=(--header 'X-Token: literal value')
# shellcheck disable=SC2218 # The production function was loaded by eval above.
archive_is_reachable
mapfile -d '' -t args < "$PROBE_ARGUMENTS"
if [ "${#args[@]}" -ne 3 ] || [ "${args[0]}" != "$RCLONE_DRIVE:$RCLONE_PATH" ] ||
   [ "${args[1]}" != "${RCLONE_FLAGS[0]}" ] || [ "${args[2]}" != "${RCLONE_FLAGS[1]}" ]
then
  fail 'rclone configuration did not reach the probe literally'
fi
ARCHIVE_SYSTEM=rsync
ARCHIVE_SERVER=archive.example.invalid
# shellcheck disable=SC2218 # The production function was loaded by eval above.
archive_is_reachable
mapfile -d '' -t args < "$PROBE_ARGUMENTS"
if [ "${#args[@]}" -ne 1 ] || [ "${args[0]}" != "$ARCHIVE_SERVER" ]
then
  fail 'non-rclone backend dispatch changed'
fi

# Exercise the actual wait functions, with only the probe, sleep and fixed
# simulation-marker paths replaced. No real cloud, mounts or /tmp trigger files
# are used by these fixtures.
load_wait_function() {
  local name="$1"
  local definition
  definition=$(sed -n "/^function $name () {$/,/^}$/p" "$REPO_ROOT/run/archiveloop")
  [ -n "$definition" ] || fail "missing $name function"
  definition=${definition//\/tmp\/archive_is_reachable/\"$TEST_TMP\/reachable-trigger\"}
  definition=${definition//\/tmp\/archive_is_unreachable/\"$TEST_TMP\/unreachable-trigger\"}
  eval "$definition"
}
load_wait_function wait_for_archive_to_be_reachable
load_wait_function wait_for_archive_to_be_unreachable
# shellcheck disable=SC2317,SC2329 # Invoked by the extracted wait functions.
function log { printf '%s\n' "$*" >> "$TEST_TMP/messages"; }
# shellcheck disable=SC2317,SC2329 # Invoked by the extracted wait functions.
function sleep { printf '%s\n' "$1" >> "$TEST_TMP/delays"; }
# shellcheck disable=SC2317,SC2329 # Invoked by the extracted wait functions.
function archive_is_reachable {
  calls=$((calls + 1))
  [ "$calls" -gt "$fail_until" ]
}
export ARCHIVE_SYSTEM=rclone
calls=0
fail_until=5
wait_for_archive_to_be_reachable
[ "$calls" -eq 6 ] || fail 'rclone did not recover after temporary failures'
[ "$(cat "$TEST_TMP/delays")" = $'5\n10\n20\n30\n30' ] \
  || fail 'rclone retry delay is not bounded exponential backoff'
if grep -F 'private-provider-url' "$TEST_TMP/messages" > /dev/null
then
  fail 'wait log includes backend details'
fi

# Two consecutive failures indicate loss; one failure followed by a successful
# check resets the counter. Polling stays at 30 seconds between cloud probes.
# shellcheck disable=SC2317,SC2329 # Invoked by the extracted wait functions.
function archive_is_reachable {
  calls=$((calls + 1))
  case "$calls" in
    2) return 0 ;;
    *) return 1 ;;
  esac
}
: > "$TEST_TMP/delays"
calls=0
wait_for_archive_to_be_unreachable
[ "$calls" -eq 4 ] || fail 'single transient failure indicated departure'
[ "$(cat "$TEST_TMP/delays")" = $'30\n30\n30' ] \
  || fail 'authenticated rclone checks were polled too frequently'

# Existing backends retain their one-second wait behavior.
ARCHIVE_SYSTEM=cifs
: > "$TEST_TMP/delays"
calls=0
# shellcheck disable=SC2317,SC2329 # Invoked by the extracted wait functions.
function archive_is_reachable {
  calls=$((calls + 1))
  [ "$calls" -gt 1 ]
}
wait_for_archive_to_be_reachable
[ "$(cat "$TEST_TMP/delays")" = 1 ] || fail 'other backend polling changed'

printf 'rclone connectivity tests passed\n'
