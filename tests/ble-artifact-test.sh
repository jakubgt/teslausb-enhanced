#!/bin/bash -eu

set -o pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname -- "$TEST_DIR")
readonly REPO_ROOT
INSTALLER="$REPO_ROOT/setup/pi/install-tesla-ble-artifact.sh"
TEST_TMP=$(mktemp -d)
readonly TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_payload() {
  local directory="$1"
  local generation="$2"
  local binary

  mkdir -p -- "$directory"
  for binary in tesla-auth-token tesla-control tesla-http-proxy tesla-jws tesla-keygen
  do
    printf '%s %s\n' "$binary" "$generation" > "$directory/$binary"
  done
}

make_archive() {
  local directory="$1"
  local archive="$2"

  tar -czf "$archive" -C "$directory" \
    ./tesla-auth-token \
    ./tesla-control \
    ./tesla-http-proxy \
    ./tesla-jws \
    ./tesla-keygen
}

artifact_hash() {
  local archive="$1"
  local digest

  digest=$(sha256sum -- "$archive")
  printf '%s\n' "${digest%% *}"
}

install_dir="$TEST_TMP/install"
valid_payload="$TEST_TMP/valid-payload"
valid_archive="$TEST_TMP/valid.tar.gz"
mkdir -p -- "$install_dir"
make_payload "$valid_payload" generation-one
make_archive "$valid_payload" "$valid_archive"
valid_hash=$(artifact_hash "$valid_archive")

if TESLA_BLE_ARTIFACT_VERSION=v1.2.3 \
   TESLA_BLE_ARTIFACT_SHA256="$valid_hash" \
   TESLA_BLE_ARTIFACT_MAX_BYTES=1 \
   TESLA_BLE_ARTIFACT_FILE="$valid_archive" \
     bash "$INSTALLER" "$install_dir" > "$TEST_TMP/oversize.log" 2>&1
then
  fail 'artifact exceeding the configured size bound passed validation'
fi
grep -F 'exceeds the 1 byte limit' "$TEST_TMP/oversize.log" > /dev/null \
  || fail 'oversize artifact failure did not identify the size limit'

TESLA_BLE_ARTIFACT_VERSION=v1.2.3 \
TESLA_BLE_ARTIFACT_SHA256="$valid_hash" \
TESLA_BLE_ARTIFACT_FILE="$valid_archive" \
  bash "$INSTALLER" "$install_dir" > "$TEST_TMP/valid.log"

[ -L "$install_dir/tesla-control" ] || fail 'tesla-control is not a stable link'
[ -L "$install_dir/tesla-keygen" ] || fail 'tesla-keygen is not a stable link'
[ -L "$install_dir/tesla-vehicle-command-current" ] || fail 'current release is not a link'
[ "$(<"$install_dir/tesla-control")" = 'tesla-control generation-one' ] \
  || fail 'installed tesla-control has unexpected content'
[ "$(<"$install_dir/tesla-keygen")" = 'tesla-keygen generation-one' ] \
  || fail 'installed tesla-keygen has unexpected content'
current_before=$(readlink -- "$install_dir/tesla-vehicle-command-current")

upgrade_payload="$TEST_TMP/upgrade-payload"
upgrade_archive="$TEST_TMP/upgrade.tar.gz"
make_payload "$upgrade_payload" generation-two
make_archive "$upgrade_payload" "$upgrade_archive"
upgrade_hash=$(artifact_hash "$upgrade_archive")
TESLA_BLE_ARTIFACT_VERSION=v1.2.4 \
TESLA_BLE_ARTIFACT_SHA256="$upgrade_hash" \
TESLA_BLE_ARTIFACT_FILE="$upgrade_archive" \
  bash "$INSTALLER" "$install_dir" > "$TEST_TMP/upgrade.log"
current_after=$(readlink -- "$install_dir/tesla-vehicle-command-current")
[ "$current_after" != "$current_before" ] || fail 'successful upgrade did not switch current release'
[ "$(<"$install_dir/tesla-control")" = 'tesla-control generation-two' ] \
  || fail 'successful upgrade did not activate tesla-control'
[ "$(<"$install_dir/tesla-keygen")" = 'tesla-keygen generation-two' ] \
  || fail 'successful upgrade did not activate tesla-keygen'
[ -f "$install_dir/$current_before/tesla-control" ] \
  || fail 'successful upgrade removed the previous content-addressed release'

# Reinstalling the same release is idempotent and keeps the same activation
# link instead of partially rebuilding live files.
TESLA_BLE_ARTIFACT_VERSION=v1.2.4 \
TESLA_BLE_ARTIFACT_SHA256="$upgrade_hash" \
TESLA_BLE_ARTIFACT_FILE="$upgrade_archive" \
  bash "$INSTALLER" "$install_dir" > "$TEST_TMP/idempotent.log"
[ "$(readlink -- "$install_dir/tesla-vehicle-command-current")" = "$current_after" ] \
  || fail 'idempotent reinstall changed the active release'

# Subsequent negative tests must prove that the upgraded release stays active.
current_before=$current_after

missing_payload="$TEST_TMP/missing-payload"
missing_archive="$TEST_TMP/missing.tar.gz"
make_payload "$missing_payload" incomplete
rm -f -- "$missing_payload/tesla-keygen"
tar -czf "$missing_archive" -C "$missing_payload" \
  ./tesla-auth-token ./tesla-control ./tesla-http-proxy ./tesla-jws
missing_hash=$(artifact_hash "$missing_archive")
if TESLA_BLE_ARTIFACT_VERSION=v1.2.4 \
   TESLA_BLE_ARTIFACT_SHA256="$missing_hash" \
   TESLA_BLE_ARTIFACT_FILE="$missing_archive" \
     bash "$INSTALLER" "$install_dir" > "$TEST_TMP/missing.log" 2>&1
then
  fail 'artifact missing the second binary passed validation'
fi
[ "$(readlink -- "$install_dir/tesla-vehicle-command-current")" = "$current_before" ] \
  || fail 'failed validation changed the active release'
[ "$(<"$install_dir/tesla-control")" = 'tesla-control generation-two' ] \
  || fail 'failed validation partially replaced tesla-control'

link_payload="$TEST_TMP/link-payload"
link_archive="$TEST_TMP/link.tar.gz"
link_target="$TEST_TMP/link-target"
make_payload "$link_payload" malicious
printf 'outside sentinel\n' > "$link_target"
rm -f -- "$link_payload/tesla-control"
ln -s "$link_target" "$link_payload/tesla-control"
make_archive "$link_payload" "$link_archive"
link_hash=$(artifact_hash "$link_archive")
if TESLA_BLE_ARTIFACT_VERSION=v1.2.5 \
   TESLA_BLE_ARTIFACT_SHA256="$link_hash" \
   TESLA_BLE_ARTIFACT_FILE="$link_archive" \
     bash "$INSTALLER" "$install_dir" > "$TEST_TMP/link.log" 2>&1
then
  fail 'artifact containing a symbolic-link member passed validation'
fi
grep -F 'unsupported archive member type' "$TEST_TMP/link.log" > /dev/null \
  || fail 'malicious link was not rejected by member type validation'
[ "$(<"$link_target")" = 'outside sentinel' ] || fail 'malicious link target was altered'
[ "$(readlink -- "$install_dir/tesla-vehicle-command-current")" = "$current_before" ] \
  || fail 'malicious archive changed the active release'

if TESLA_BLE_ARTIFACT_VERSION='../escape' \
   TESLA_BLE_ARTIFACT_SHA256="$valid_hash" \
   TESLA_BLE_ARTIFACT_FILE="$valid_archive" \
     bash "$INSTALLER" "$install_dir" > /dev/null 2>&1
then
  fail 'unsafe artifact version override was accepted'
fi
if TESLA_BLE_ARTIFACT_VERSION=v1.2.3 \
   TESLA_BLE_ARTIFACT_SHA256=not-a-sha256 \
   TESLA_BLE_ARTIFACT_FILE="$valid_archive" \
     bash "$INSTALLER" "$install_dir" > /dev/null 2>&1
then
  fail 'unsafe artifact hash override was accepted'
fi

unsafe_current_dir="$TEST_TMP/unsafe-current-install"
mkdir -p "$unsafe_current_dir"
ln -s /tmp "$unsafe_current_dir/tesla-vehicle-command-current"
if TESLA_BLE_ARTIFACT_VERSION=v1.2.3 \
   TESLA_BLE_ARTIFACT_SHA256="$valid_hash" \
   TESLA_BLE_ARTIFACT_FILE="$valid_archive" \
     bash "$INSTALLER" "$unsafe_current_dir" > "$TEST_TMP/unsafe-current.log" 2>&1
then
  fail 'installer accepted a current release link outside its managed directory'
fi

printf 'BLE artifact tests passed\n'
