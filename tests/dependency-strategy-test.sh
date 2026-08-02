#!/bin/bash -eu

TEST_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(dirname -- "$TEST_DIR")
readonly REPO_ROOT
CONFIGURE="$REPO_ROOT/setup/pi/configure.sh"
BLE_INSTALLER="$REPO_ROOT/setup/pi/install-tesla-ble-artifact.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -F "boto3==1.34.162" "$CONFIGURE" > /dev/null \
  || fail 'SNS dependency is not pinned'
grep -F "matrix-nio==0.24.0" "$CONFIGURE" > /dev/null \
  || fail 'Matrix dependency is not pinned'
grep -F 'python3 -m venv' "$CONFIGURE" > /dev/null \
  || fail 'isolated Python environment is not used'
grep -F -- '--retries "${PIP_RETRIES:-3}" --timeout "${PIP_TIMEOUT_SECONDS:-30}"' \
  "$CONFIGURE" > /dev/null || fail 'Python dependency installation is not bounded'
if grep -F 'EXTERNALLY-MANAGED' "$CONFIGURE" > /dev/null
then
  fail 'configure still removes the distro Python protection marker'
fi
if grep -F 'github.com/marcone/rsync/releases' "$CONFIGURE" > /dev/null
then
  fail 'configure still downloads an unverified prebuilt rsync executable'
fi
grep -F 'copy_script run/keep-awake-pid.sh' "$CONFIGURE" > /dev/null \
  || fail 'exact-process PID helper is not installed'
grep -F 'RuntimeDirectory=teslausb' "$CONFIGURE" > /dev/null \
  || fail 'systemd runtime state directory is not provisioned'
# shellcheck disable=SC2016 # The literal expansion belongs in the installer.
grep -F 'releases/download/${artifact_version}' "$BLE_INSTALLER" > /dev/null \
  || fail 'BLE artifact URL is not version-pinned'
grep -F '6e1411a22a948760796c5b19c97337ea2431314d37486e060402e260b6fd21a4' \
  "$BLE_INSTALLER" > /dev/null || fail 'BLE artifact checksum is missing'
if grep -F 'tesla-vehicle-command-arm-binaries/releases/latest' "$BLE_INSTALLER" > /dev/null
then
  fail 'BLE artifact still follows an unpinned latest release'
fi
grep -F 'unsupported archive member type' "$BLE_INSTALLER" > /dev/null \
  || fail 'BLE archive member types are not validated'
grep -F -- '--max-filesize "$artifact_max_bytes"' "$BLE_INSTALLER" > /dev/null \
  || fail 'BLE artifact download size is not bounded'
grep -F 'tesla-vehicle-command-current' "$BLE_INSTALLER" > /dev/null \
  || fail 'BLE binary pair lacks an atomic current release link'

printf 'dependency strategy tests passed\n'
